
promptname(level, name) = "$level|$name> "

function write_prompt(terminal, mode)
    LineEdit.write_prompt(terminal, mode, LineEdit.hascolor(terminal))
end

# Whether any session currently has the terminal switched to the alternate screen
const _ALT_SCREEN = Ref(false)

# Sticky (full-screen) rendering needs a real terminal that understands the
# escape codes; everything else (tests, dumb terminals) keeps the scrolling
# transcript
function sticky_active(state::DebuggerState)
    STICKY[] || return false
    term = state.terminal
    term isa REPL.Terminals.TTYTerminal || return false
    return term.term_type != "dumb"
end

function enter_alt_screen(state::DebuggerState)
    if sticky_active(state) && !_ALT_SCREEN[]
        print(output_stream(state), "\e[?1049h\e[H")
        _ALT_SCREEN[] = true
        state.owns_alt_screen = true
    end
end

function exit_alt_screen(state::DebuggerState)
    if state.owns_alt_screen && _ALT_SCREEN[]
        _ALT_SCREEN[] = false
        state.owns_alt_screen = false
        print(output_stream(state), "\e[?1049l")
    end
end

# Print `msg` if the session is on the main screen; otherwise defer it to when
# the alternate screen is left, so it is not restored away with it
function print_or_defer(state::DebuggerState, msg::String)
    if state.owns_alt_screen
        state.exit_output = something(state.exit_output, "") * msg
    else
        print(output_stream(state), msg)
    end
end

# In full-screen mode the session runs on the alternate screen, which has no
# scrollback — output taller than the screen (`?`, a deep `bt`, ...) would
# simply be cut off. Show such output in a scrollable pager instead.
function print_or_page(state::DebuggerState, str::AbstractString)
    io = output_stream(state)
    if sticky_active(state)
        rows = safe_displaysize(io)[1]
        if count(==('\n'), str) + 1 > rows - 2
            pager = TerminalMenus.Pager(str; pagesize = max(rows - 5, 4))
            TerminalMenus.request(state.terminal, pager)
            return nothing
        end
    end
    print(io, str)
    return nothing
end

function show_status(state::DebuggerState)
    io = output_stream(state)
    if sticky_active(state)
        # Draw the status at the top of the screen. Clearing the screen and
        # then printing makes the terminal render an empty frame in between
        # (visible as blinking), so instead overwrite in place: move home,
        # erase each line as it is rewritten, and erase whatever remains of
        # the previous frame below at the end.
        buf = IOBuffer()
        ioc = IOContext(IOContext(buf, io), :displaysize => safe_displaysize(io))
        print_status(ioc, state)
        str = String(take!(buf))
        print(io, "\e[H", replace(str, "\n" => "\e[K\n"), "\e[0J")
    else
        print_status(io, state)
    end
end

function RunDebugger(frame, repl = nothing, terminal = nothing; initial_continue=false)
    if repl === nothing
        if !isdefined(Base, :active_repl)
            error("Debugger.jl needs to be run in a Julia REPL")
        end
        repl = Base.active_repl
    end
    if !isa(repl, REPL.LineEditREPL)
        error("Debugger.jl requires a LineEditREPL type of REPL")
    end

    if terminal === nothing
        terminal = Base.active_repl.t
    end
    state = DebuggerState(; frame=frame, repl=repl, terminal=terminal)

    # Setup debug panel
    normal_prefix = Sys.iswindows() ? "\e[33m" : "\e[38;5;166m"
    compiled_prefix = "\e[96m"
    panel = LineEdit.Prompt(promptname(state.level, "debug");
        prompt_prefix = () -> state.interp == NonRecursiveInterpreter() ? compiled_prefix : normal_prefix,
        prompt_suffix = Base.text_colors[:normal],
        on_enter = s->true)

    panel.hist = REPL.REPLHistoryProvider(Dict{Symbol,Any}(:debug => panel))
    REPL.history_reset_state(panel.hist)

    if VERSION < v"1.13-"
        search_prompt, skeymap = LineEdit.setup_search_keymap(panel.hist)
        search_prompt.complete = REPL.LatexCompletions()
    end

    state.main_mode = panel

    panel.on_done = (s,buf,ok)->begin
        line = String(take!(buf))
        old_level = state.level
        if !ok || strip(line) == "q"
            LineEdit.transition(s, :abort)
            LineEdit.reset_state(s)
            return false
        end
        if length(panel.hist.history) == 0
            printstyled(stderr, "no previous command executed\n"; color=Base.error_color())
            return false
        end
        if isempty(strip(line))
            command = panel.hist.history[end]
        else
            command = strip(line)
        end
        do_print_status = true
        if !(command isa AbstractString)
            command = command.content
        end
        cmd1 = split(command,' ')[1]
        do_print_status = try
            execute_command(state, Val{Symbol(cmd1)}(), command)
        catch err
            if state.frame === nothing
                LineEdit.transition(s, :abort)
                LineEdit.reset_state(s)
                return false
            end
            buf = IOBuffer()
            io = IOContext(buf, output_stream(state))
            if err isa InterruptException
                printstyled(io, "Interrupted: the command was aborted, the debugger is still paused where it was.\n";
                            color=Base.error_color())
            else
                # JuliaInterpreter keeps the frames linked when an exception
                # escapes the interpreted code, so the backtrace reaches the
                # actual throw site
                Base.display_error(io, err, JuliaInterpreter.leaf(state.frame))
                printstyled(io, "The error terminated the command; the debugger is still paused where it was.\n";
                            color=:light_black)
                # Comment below out if you are debugging the Debugger
                #Base.display_error(Base.pipe_writer(terminal), err, catch_backtrace())
            end
            # Drop the dead callee frames the failed command left behind so the
            # session continues cleanly from the current statement
            state.frame.callee = nothing
            print_or_page(state, String(take!(buf)))
            LineEdit.reset_state(s)
            return true
        end
        if old_level != state.level
            panel.prompt = promptname(state.level, "debug")
        end
        LineEdit.reset_state(s)
        if state.frame === nothing
            LineEdit.transition(s, :abort)
            LineEdit.reset_state(s)
            return false
        end
        if do_print_status
            show_status(state)
        end
        return true
    end

    repl_switch = Dict{Any,Any}(
        '`' => function (s,args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                prompt = julia_prompt(state)
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, prompt) do
                    LineEdit.state(s, prompt).input_buffer = buf
                end
            else
                LineEdit.edit_insert(s, '`')
            end
        end,
        'C' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                toggle_mode(state)
                write(state.terminal, '\r')
                write_prompt(state.terminal, panel)
            else
                LineEdit.edit_insert(s, "C")
            end
        end,
        'L' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                toggle_lowered(state)
                println(output_stream(state))
                show_status(state)
                write_prompt(state.terminal, panel)
            else
                LineEdit.edit_insert(s, "L")
            end
        end,
        'T' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                i = findfirst(==(VARIABLE_TYPES[]), TYPE_DISPLAY_MODES)
                VARIABLE_TYPES[] = TYPE_DISPLAY_MODES[mod1(something(i, 0) + 1, length(TYPE_DISPLAY_MODES))]
                io = output_stream(state)
                println(io)
                show_status(state)
                printstyled(io, "variable types: ", VARIABLE_TYPES[], "\n"; color=:light_black)
                write_prompt(state.terminal, panel)
            else
                LineEdit.edit_insert(s, "T")
            end
        end,
        'S' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                STICKY[] = !STICKY[]
                io = output_stream(state)
                if STICKY[]
                    enter_alt_screen(state)
                else
                    exit_alt_screen(state)
                end
                println(io)
                show_status(state)
                printstyled(io, "sticky mode: ", STICKY[] ? "on" : "off", "\n"; color=:light_black)
                write_prompt(state.terminal, panel)
            else
                LineEdit.edit_insert(s, "S")
            end
        end,
        '+' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                NUM_SOURCE_LINES_UP_DOWN[] += 1
                println(output_stream(state))
                show_status(state)
                write_prompt(state.terminal, panel)
            else
                LineEdit.edit_insert(s, "+")
            end
        end,
        '-' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                NUM_SOURCE_LINES_UP_DOWN[] = max(1, NUM_SOURCE_LINES_UP_DOWN[] - 1)
                println(output_stream(state))
                show_status(state)
                write_prompt(state.terminal, panel)
            else
                LineEdit.edit_insert(s, "-")
            end
        end
    )
    
    keymaps = Dict{Any,Any}[LineEdit.history_keymap, LineEdit.default_keymap, LineEdit.escape_defaults]

    if VERSION < v"1.13-"
        pushfirst!(keymaps, skeymap)
    end

    state.standard_keymap = keymaps
    panel.keymap_dict = LineEdit.keymap([repl_switch;state.standard_keymap])

    # In sticky mode the session runs on the terminal's alternate screen (like
    # `less` or `vim`), so quitting restores the terminal as it was
    enter_alt_screen(state)
    try
        # If a breakpoint is set on the statement we are already stopped at, `c` would
        # step over it, so stay put and show the prompt instead (#134)
        if initial_continue && !JuliaInterpreter.shouldbreak(state.frame, state.frame.pc)
            try
                execute_command(state, Val(:c), "c")
            catch err
                # Buffer error printing
                io = IOContext(IOBuffer(), output_stream(state))
                Base.display_error(io, err, JuliaInterpreter.leaf(state.frame))
                print_or_defer(state, String(take!(io.io)))
                return
            end
            state.frame === nothing && return state.overall_result
        end
        if pc_expr(state.frame) === nothing
            JuliaInterpreter.maybe_next_call!(state.frame)
        end
        show_status(state)

        prompts = LineEdit.TextInterface[panel]

        if VERSION < v"1.13-"
            push!(prompts, search_prompt)
        end

        interface = LineEdit.ModalInterface(prompts)
        mistate = LineEdit.init_state(terminal, interface)
        previous_mistate = repl.mistate
        repl.mistate = mistate
        try
            REPL.run_interface(terminal, interface, mistate)
        finally
            repl.mistate = previous_mistate
        end
    finally
        exit_alt_screen(state)
        if state.exit_output !== nothing
            print(output_stream(state), state.exit_output)
            state.exit_output = nothing
        end
    end

    return state.overall_result
end

@static if VERSION ≥ v"1.11.5"
    # Starting from https://github.com/JuliaLang/julia/pull/57773, `print_response`
    # hands over the evaluation to the backend using a `Channel` for synchronization.
    # However, this causes a deadlock for Debugger because we call this from the backend already.
    function print_response(repl, response, show_value::Bool, have_color::Bool)
        repl.waserror = response[2]
        backend = nothing # don't defer evaluation to the REPL backend, do it eagerly.
        REPL.with_repl_linfo(repl) do io
            io = IOContext(io, :module => Base.active_module(repl)::Module)

            REPL.print_response(io, response, backend, show_value, have_color, REPL.specialdisplay(repl))
        end
    end
else
    print_response(repl, response, show_value::Bool, have_color::Bool) = REPL.print_response(repl, response, show_value, have_color)
end

function julia_prompt(state::DebuggerState)
    # Return early if this has already been called on the state
    isassigned(state.julia_prompt) && return state.julia_prompt[]

    julia_prompt = LineEdit.Prompt(() -> promptname(state.level, "julia");
        # Copy colors from the prompt object
        prompt_prefix = state.repl.prompt_color,
        prompt_suffix = (state.repl.envcolors ? Base.input_color : state.repl.input_color),
        complete = DebugCompletionProvider(state),
        on_enter = REPL.return_callback)
    julia_prompt.hist = state.main_mode.hist
    julia_prompt.hist.mode_mapping[:julia] = julia_prompt

    julia_prompt.on_done = (s,buf,ok)->begin
        if !ok
            LineEdit.transition(s, :abort)
            return false
        end
        command = String(take!(buf))
        response = _eval_code(active_frame(state), command)
        print_response(state.repl, response, true, true)
        println(state.terminal)
        LineEdit.reset_state(s)
    end
    julia_prompt.keymap_dict = LineEdit.keymap([REPL.mode_keymap(state.main_mode); state.standard_keymap])
    state.julia_prompt[] = julia_prompt
    return julia_prompt
end

function _eval_code(frame::Frame, code::AbstractString)
    try
        return JuliaInterpreter.eval_code(frame, code), false
    catch
        return scrub_eval_backtrace(Base.current_exceptions()), true
    end
end

# Remove the debugger machinery (`eval_code` and below: Debugger, LineEdit,
# `RunDebugger`, ...) from the backtraces of errors thrown by code evaluated
# in evaluation mode, like the REPL does for its own errors
function scrub_eval_backtrace(stack)
    return Base.ExceptionStack(Any[
        (exception = entry.exception, backtrace = scrub_eval_backtrace(entry.backtrace))
        for entry in stack])
end

function scrub_eval_backtrace(bt::Union{Vector, Nothing})
    bt === nothing && return bt
    frames = bt isa Vector{Base.StackTraces.StackFrame} ? copy(bt) : Base.stacktrace(bt)
    i = findfirst(fr -> !fr.from_c && fr.func === :eval_code, frames)
    if i !== nothing
        # the `eval` frame `eval_code` calls into is machinery as well
        if i > 1 && frames[i-1].func === :eval
            i -= 1
        end
        deleteat!(frames, i:length(frames))
    end
    return frames
end

# Completions

# Julia 1.12 removed `completion_text(::BslashCompletion)` in favor of the
# `named_completion` API (JuliaLang/julia#54800).
@static if isdefined(REPLCompletions, :named_completion)
    _completion_text(c) = REPLCompletions.named_completion(c).completion
else
    _completion_text(c) = REPLCompletions.completion_text(c)
end

# The `hint` positional argument to `REPLCompletions.completions` was added in
# Julia 1.11 (JuliaLang/julia#51229).
@static if VERSION >= v"1.11"
    _completions(full, pos, mod, hint) = REPLCompletions.completions(full, pos, mod, true, hint)
else
    _completions(full, pos, mod, hint) = REPLCompletions.completions(full, pos, mod, true)
end

mutable struct DebugCompletionProvider <: REPL.CompletionProvider
    state::DebuggerState
end

function LineEdit.complete_line(c::DebugCompletionProvider, s; hint=false)
    partial = REPL.beforecursor(s.input_buffer)
    full = LineEdit.input_string(s)

    ret, range, should_complete = completions(c, full, partial; hint=hint)
    return ret, partial[range], should_complete
end

function completions(c::DebugCompletionProvider, full, partial; hint::Bool=false)
    frame = c.state.frame
    pos = lastindex(partial)

    # completions in the context of the frame's module
    comps1, range1, should_complete1 = _completions(full, pos, moduleof(frame), hint)
    ret1 = map(_completion_text, comps1)

    # completions where the frame's locals are visible as globals of a temporary module
    ignore_local(v) = v.name == Symbol("#self#") && (v.value isa Type || sizeof(v.value) == 0)
    m = Module()
    for v in locals(frame)
        ignore_local(v) && continue
        Base.eval(m, :($(v.name) = $(QuoteNode(v.value))))
    end

    comps2, range2, should_complete2 = Base.invokelatest(_completions, full, pos, m, hint)
    ret2 = map(_completion_text, comps2)

    # The two passes can return completions of different kinds (e.g. dict key
    # completions for a local dict vs. path completions inside the string) with
    # different replacement ranges. Merging those would corrupt the insertion,
    # so only merge when the ranges agree; otherwise pick one pass, preferring
    # the one whose completion consumed more context (smaller range start).
    if range1 == range2
        ret = sort!(unique!(vcat(ret1, ret2)))
        range = range1
        should_complete = should_complete1 | should_complete2
    elseif isempty(ret2) || (!isempty(ret1) && first(range1) < first(range2))
        ret, range, should_complete = ret1, range1, should_complete1
    else
        ret, range, should_complete = ret2, range2, should_complete2
    end

    # Attempt to allow values to be garbage collected
    # because I don't think Julia ever GCs modules.
    for v in locals(frame)
        ignore_local(v) && continue
        Base.eval(m, :($(v.name) = nothing))
    end

    ret, range, should_complete
end
