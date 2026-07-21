using REPL.TerminalMenus
using Logging

# Drive the interactive menus headlessly: a TTYTerminal over a BufferStream
# with scripted keystrokes. Entering raw mode fails on a BufferStream, which
# `TerminalMenus.request` handles with a warning; silence it.

const KEYDICT = Dict(:up => "\e[A", :down => "\e[B", :enter => "\r")

function scripted_terminal(keys...)
    in_stream = Base.BufferStream()
    for key in keys
        write(in_stream, key isa Symbol ? KEYDICT[key] : string(key))
    end
    return REPL.Terminals.TTYTerminal("xterm", in_stream, IOBuffer(), IOBuffer())
end

function menu_state(frame, keys...)
    return Debugger.DebuggerState(; frame=frame, terminal=scripted_terminal(keys...))
end

quietly(f) = with_logger(f, NullLogger())

function f_menu_inner(x)
    return x + 1
end
function f_menu_outer(x)
    y = 2x
    return f_menu_inner(y)
end

@testset "menus" begin
    @testset "menus_available" begin
        state = menu_state(nothing)
        @test Debugger.menus_available(state)
        Debugger.config(menus = false)
        @test !Debugger.menus_available(state)
        Debugger.config(menus = true)
        @test !Debugger.menus_available(dummy_state(JuliaInterpreter.enter_call(f_menu_inner, 1)))
    end

    @testset "sticky_active gating" begin
        # sticky (full-screen) rendering needs a real terminal
        state = menu_state(nothing)
        was_sticky = Debugger.STICKY[]
        try
            Debugger.config(sticky = true)
            @test Debugger.sticky_active(state)
            @test !Debugger.sticky_active(dummy_state(nothing)) # no terminal
            dumb = Debugger.DebuggerState(; frame=nothing,
                terminal=REPL.Terminals.TTYTerminal("dumb", Base.BufferStream(), IOBuffer(), IOBuffer()))
            @test !Debugger.sticky_active(dumb)
            Debugger.config(sticky = false)
            @test !Debugger.sticky_active(state)
        finally
            Debugger.config(sticky = was_sticky)
        end
    end

    @testset "alt screen lifecycle" begin
        was_sticky = Debugger.STICKY[]
        state = menu_state(nothing)
        try
            Debugger.config(sticky = true)
            @test !Debugger._ALT_SCREEN[]
            Debugger.enter_alt_screen(state)
            @test Debugger._ALT_SCREEN[]
            @test state.owns_alt_screen
            @test occursin("\e[?1049h", String(take!(state.terminal.out_stream)))
            # a nested session does not take over the alternate screen
            state2 = menu_state(nothing)
            Debugger.enter_alt_screen(state2)
            @test !state2.owns_alt_screen
            Debugger.exit_alt_screen(state2) # non-owner: no-op
            @test Debugger._ALT_SCREEN[]
            # output deferred while owning the alternate screen
            Debugger.print_or_defer(state, "boom\n")
            @test state.exit_output == "boom\n"
            Debugger.exit_alt_screen(state)
            @test !Debugger._ALT_SCREEN[]
            @test !state.owns_alt_screen
            @test occursin("\e[?1049l", String(take!(state.terminal.out_stream)))
            # on the main screen output prints directly
            Debugger.print_or_defer(state2, "direct\n")
            @test occursin("direct", String(take!(state2.terminal.out_stream)))
        finally
            Debugger._ALT_SCREEN[] = false
            Debugger.config(sticky = was_sticky)
        end
    end

    @testset "print_or_page" begin
        was_sticky = Debugger.STICKY[]
        try
            Debugger.config(sticky = true)
            # short output prints directly
            state = menu_state(nothing)
            Debugger.print_or_page(state, "short\n")
            @test String(take!(state.terminal.out_stream)) == "short\n"
            # output taller than the screen opens a pager (scripted `q` closes it)
            state = menu_state(nothing, 'q')
            long = join(("line $i" for i in 1:100), '\n') * "\n"
            quietly(() -> Debugger.print_or_page(state, long))
            out = String(take!(state.terminal.out_stream))
            @test occursin("line 1", out)
            @test !occursin("line 99", out) # not scrolled to
            # the `?` help is paged in full-screen mode
            state = menu_state(nothing, 'q')
            quietly(() -> execute_command(state, Val{:help}(), "?"))
            out = String(take!(state.terminal.out_stream))
            @test occursin("Debugger commands", out)
            # without sticky mode, long output prints in full
            Debugger.config(sticky = false)
            state = menu_state(nothing)
            Debugger.print_or_page(state, long)
            @test occursin("line 99", String(take!(state.terminal.out_stream)))
        finally
            Debugger.config(sticky = was_sticky)
        end
    end

    @testset "ActionMenu basics" begin
        picked = Ref(0)
        menu = Debugger.ActionMenu([:a, :b, :c];
            writerow = (io, row, idx) -> print(io, idx, ") ", row),
            onpick = (m, idx) -> (picked[] = idx; true),
            help = "help line")
        @test TerminalMenus.numoptions(menu) == 3
        @test TerminalMenus.header(menu) == "help line"
        buf = IOBuffer()
        TerminalMenus.writeline(buf, menu, 2, false)
        @test String(take!(buf)) == "2) b"
        # deleting rows clamps the cursor and exits when empty
        menu.cursor[] = 3
        @test !Debugger.delete_row!(menu, 3)
        @test menu.cursor[] == 2
        @test !Debugger.delete_row!(menu, 1)
        @test Debugger.delete_row!(menu, 1)

        state = menu_state(nothing, :down, :enter)
        menu = Debugger.ActionMenu([:a, :b, :c];
            writerow = (io, row, idx) -> print(io, row),
            onpick = (m, idx) -> (m.selected = idx; true))
        sel = quietly() do
            Debugger.run_menu(menu, state)
        end
        @test sel == 2

        # q cancels
        state = menu_state(nothing, 'q')
        menu = Debugger.ActionMenu([:a, :b];
            writerow = (io, row, idx) -> print(io, row))
        @test quietly(() -> Debugger.run_menu(menu, state)) === nothing
    end

    @testset "trunc_to_width" begin
        @test Debugger.trunc_to_width("short", 10) == "short"
        trunced = Debugger.trunc_to_width("a very long string", 10)
        @test textwidth(trunced) <= 10
        @test endswith(trunced, Debugger.ellipsis())
        # menu rows must stay single printable lines
        @test Debugger.trunc_to_width("a\nb\tc", 80) == "a b c"
        @test Debugger.trunc_to_width("a\e[1mb", 80) == "a[1mb" # control chars removed
        # the ascii ellipsis is 3 columns wide and must fit in the budget
        Debugger.config(charset = :ascii)
        try
            trunced = Debugger.trunc_to_width("abcdefgh", 5)
            @test textwidth(trunced) <= 5
            @test endswith(trunced, "...")
            # widths smaller than the ellipsis hard-cut instead of overflowing
            @test Debugger.trunc_to_width("abcd", 2) == "ab"
            @test Debugger.trunc_to_width("abcd", 0) == ""
        finally
            Debugger.config(charset = :unicode)
        end
        @test Debugger.trunc_to_width("abcd", 0) == ""
        @test textwidth(Debugger.trunc_to_width("abcd", 2)) <= 2
    end

    @testset "breakpoint menu" begin
        JuliaInterpreter.remove()
        bp1 = JuliaInterpreter.breakpoint(f_menu_inner)
        bp2 = JuliaInterpreter.breakpoint(f_menu_outer)
        try
            # toggle the first breakpoint with space, then quit
            state = menu_state(nothing, ' ', 'q')
            quietly(() -> Debugger.breakpoint_menu(state))
            @test !bp1.enabled[]
            @test bp2.enabled[]
            # toggle it back with enter
            state = menu_state(nothing, :enter, 'q')
            quietly(() -> Debugger.breakpoint_menu(state))
            @test bp1.enabled[]
            # delete the first breakpoint
            state = menu_state(nothing, 'd', 'q')
            quietly(() -> Debugger.breakpoint_menu(state))
            @test length(JuliaInterpreter.breakpoints()) == 1
            @test JuliaInterpreter.breakpoints()[1] === bp2
            # toggle break-on-error via its pseudo row (last-1 row: END, up? navigate: bp2, :error, :throw)
            was_error = JuliaInterpreter.break_on_error[]
            state = menu_state(nothing, :down, ' ', 'q')
            quietly(() -> Debugger.breakpoint_menu(state))
            @test JuliaInterpreter.break_on_error[] == !was_error
            state = menu_state(nothing, :down, ' ', 'q')
            quietly(() -> Debugger.breakpoint_menu(state))
            @test JuliaInterpreter.break_on_error[] == was_error
            # add a breakpoint from the menu: `a` prompts for a location and reopens
            state = menu_state(nothing, 'a', "f_menu_inner\n", 'q')
            quietly(() -> Debugger.breakpoint_menu(state))
            @test length(JuliaInterpreter.breakpoints()) == 2
            @test any(bp -> bp isa JuliaInterpreter.BreakpointSignature && bp.f === f_menu_inner,
                      JuliaInterpreter.breakpoints())
            # an empty line cancels
            state = menu_state(nothing, 'a', "\n", 'q')
            quietly(() -> Debugger.breakpoint_menu(state))
            @test length(JuliaInterpreter.breakpoints()) == 2
        finally
            JuliaInterpreter.remove()
            JuliaInterpreter.break_off(:error)
        end
    end

    @testset "breakpoint menu row rendering" begin
        JuliaInterpreter.remove()
        bp = JuliaInterpreter.breakpoint(f_menu_inner)
        try
            io = IOContext(IOBuffer(), :displaysize => (24, 80))
            Debugger.bp_menu_writerow(io, bp, 1)
            str = String(take!(io.io))
            @test occursin("f_menu_inner", str)
            @test occursin("1]", str)
            io = IOContext(IOBuffer(), :displaysize => (24, 80))
            Debugger.bp_menu_writerow(io, :error, 2)
            @test occursin("break on error", String(take!(io.io)))
            @test Debugger.bp_location(bp) !== nothing
        finally
            JuliaInterpreter.remove()
        end
        # typed breakpoints: `sig` includes the callable type; `o` must still
        # resolve the method location
        bp_typed = JuliaInterpreter.breakpoint(f_menu_inner, Tuple{Int})
        try
            loc = Debugger.bp_location(bp_typed)
            @test loc !== nothing
            @test endswith(loc[1], "menus.jl")
        finally
            JuliaInterpreter.remove()
        end
    end

    @testset "frame menu via f command" begin
        frame = JuliaInterpreter.enter_call(f_menu_outer, 3)
        state = menu_state(frame, :down, :enter)
        execute_command(state, Val{:s}(), "s") # step into f_menu_inner: two frames
        @test Debugger.stacklength(state.frame) == 2
        quietly(() -> execute_command(state, Val{:f}(), "f"))
        @test state.level == 2
        # cancelling leaves the level untouched
        write(state.terminal.in_stream, "q")
        quietly(() -> execute_command(state, Val{:f}(), "f"))
        @test state.level == 2
    end

    @testset "watch menu" begin
        frame = JuliaInterpreter.enter_call(f_menu_inner, 1)
        state = menu_state(frame, 'd', 'q')
        empty!(state.watch_list)
        Debugger.add_watch_entry!(state, "x + 1")
        Debugger.add_watch_entry!(state, "x + 2")
        quietly(() -> Debugger.watch_menu(state))
        @test length(state.watch_list) == 1
        @test state.watch_list[1] == :(x + 2)
        empty!(state.watch_list)
    end

    @testset "watches evaluate once per w command" begin
        global watch_eval_counter = 0
        frame = JuliaInterpreter.enter_call(f_menu_inner, 1)
        state = menu_state(frame, 'q')
        empty!(state.watch_list)
        Debugger.add_watch_entry!(state, "global watch_eval_counter += 1")
        quietly(() -> execute_command(state, Val{:w}(), "w"))
        @test watch_eval_counter == 1
        empty!(state.watch_list)
    end
end

@testset "focus menu" begin
    Debugger.FOCUS[] = nothing
    Debugger.invalidate_policy_cache!()
    try
        # toggle Main off with space (row order depends on the environment, so
        # navigate to it), back on with enter; the row stays for re-toggling
        rows = Debugger.focus_menu_rows()
        idx = findfirst(==(Main), rows)
        state = menu_state(nothing, fill(:down, idx - 1)..., ' ', 'q')
        quietly(() -> Debugger.focus_menu(state))
        @test Main ∉ Debugger.interpreted_modules()
        rows = Debugger.focus_menu_rows()
        idx = findfirst(==(Main), rows)
        @test idx !== nothing # still shown, just toggled off
        state = menu_state(nothing, fill(:down, idx - 1)..., :enter, 'q')
        quietly(() -> Debugger.focus_menu(state))
        @test Main ∈ Debugger.interpreted_modules()

        # add a module from the menu: `a` prompts for a name and reopens
        state = menu_state(nothing, 'a', "JuliaInterpreter\n", 'q')
        quietly(() -> Debugger.focus_menu(state))
        @test JuliaInterpreter ∈ Debugger.interpreted_modules()

        # row rendering
        buf = IOBuffer()
        Debugger.focus_menu_writerow(IOContext(buf, :displaysize => (24, 80)), Main, 1)
        @test occursin("Main", String(take!(buf)))
    finally
        Debugger.FOCUS[] = nothing
        empty!(Debugger.SESSION_UNFOCUSED)
        Debugger.invalidate_policy_cache!()
    end
end

@testset "focus command falls back to a text list without menus" begin
    Debugger.config(menus = false)
    try
        state = menu_state(nothing)
        execute_command(state, Val{:focus}(), "focus")
        out = String(take!(state.terminal.out_stream))
        @test occursin("Focus set", out)
        @test occursin("Main", out)
    finally
        Debugger.config(menus = true)
    end
end

@testset "frameless bp commands (debug> mode)" begin
    JuliaInterpreter.remove()
    try
        state = dummy_state(nothing)
        @test Debugger.add_breakpoint!(state, "f_menu_inner")
        @test length(JuliaInterpreter.breakpoints()) == 1
        @test !Debugger.add_breakpoint!(state, "12") # line bp needs a session
        @test Debugger.remove_breakpoint!(state, "f_menu_inner")
        @test isempty(JuliaInterpreter.breakpoints())
    finally
        JuliaInterpreter.remove()
    end
end

@testset "install_repl_mode" begin
    repl = REPL.LineEditREPL(scripted_terminal(), true)
    repl.interface = REPL.setup_interface(repl)
    nmodes = length(repl.interface.modes)
    mode = Debugger.install_repl_mode(repl)
    @test mode isa REPL.LineEdit.Prompt
    @test mode.prompt == Debugger.DEBUG_MODE_PROMPT
    @test length(repl.interface.modes) == nmodes + 1
    @test repl.interface.modes[end] === mode
    # installing again does not add a second mode
    @test Debugger.install_repl_mode(repl) === mode
    @test length(repl.interface.modes) == nmodes + 1
end

@testset "debug_mode_parse" begin
    ex = Debugger.debug_mode_parse("sin(1.0)")
    @test isexpr(ex, :macrocall)
    @test ex.args[1] === getfield(Debugger, Symbol("@enter"))
    ex = Debugger.debug_mode_parse("bp add f_menu_inner")
    @test isexpr(ex, :call)
    @test ex.args[1] === Debugger.debug_mode_bp_command
    @test ex.args[2] == "bp add f_menu_inner"
    ex = Debugger.debug_mode_parse("?")
    @test isexpr(ex, :call)
    @test ex.args[1] === Debugger.debug_mode_help
    # semicolon-separated statements arrive as a nested :toplevel, which cannot
    # be spliced into the thunk `@enter` builds
    ex = Debugger.debug_mode_parse("x = 1; x + 1")
    @test isexpr(ex, :macrocall)
    @test !any(a -> isexpr(a, :toplevel), ex.args)
    ex = Debugger.debug_mode_parse("x = 1\nx + 1")
    @test isexpr(ex, :macrocall)
    @test !any(a -> isexpr(a, :toplevel), ex.args)
    # whitespace-only input is a no-op
    @test Debugger.debug_mode_parse("  ") === nothing
end

@testset "config" begin
    old = Debugger.config()
    try
        cfg = Debugger.config(vartypes = :none, context_lines = 7, charset = :ascii, max_vars = 3)
        @test cfg.vartypes === :none
        @test cfg.context_lines == 7
        @test cfg.charset === :ascii
        @test cfg.max_vars == 3
        @test Debugger.ellipsis() == "..."
        @test_throws ArgumentError Debugger.config(vartypes = :junk)
        @test_throws ArgumentError Debugger.config(charset = :junk)
    finally
        Debugger.config(; theme=old.theme, highlight=old.highlight, context_lines=old.context_lines,
                        vartypes=old.vartypes, max_vars=old.max_vars, sticky=old.sticky,
                        charset=old.charset, menus=old.menus)
    end
end
