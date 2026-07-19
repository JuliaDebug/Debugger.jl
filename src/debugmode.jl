# A top-level `debug>` REPL mode, entered with `)` at an empty `julia>` prompt
# and left with backspace. Breakpoints can be managed with the usual `bp`
# commands (including the interactive menu) without an active debug session,
# and any other input is debugged as if run through `@enter`.

const DEBUG_MODE_PROMPT = "debug> "

# The module the REPL currently evaluates in (`REPL.activate(Mod)` changes it);
# used to resolve breakpoint expressions outside of a debug session
function repl_active_module()
    if isdefined(REPL, :active_module)
        try
            return REPL.active_module()::Module
        catch
        end
    end
    if isdefined(Base, :active_module)
        try
            return Base.active_module()::Module
        catch
        end
    end
    return Main
end

# State for breakpoint commands executed outside of a debug session
function frameless_state()
    repl = Base.active_repl
    return DebuggerState(; frame=nothing, repl=repl, terminal=repl.t)
end

function debug_mode_bp_command(line::String)
    execute_command(frameless_state(), Val(:bp), line)
    return nothing
end

function debug_mode_help()
    display(
        @md_str """
        # Debug mode
        Any expression you enter is debugged as if run through `@enter`.

        Breakpoints can be managed from here (they persist across debug sessions):\\
        - `bp`: interactively manage breakpoints (toggle, delete, open in editor)\\
        - `bp add func [:line] [cond]`: add a breakpoint to function `func`\\
        - `bp add "file.jl":line [cond]`: add a breakpoint at a file location\\
        - `bp rm [i|func|"file.jl":line]`: remove all or matching breakpoints\\
        - `bp toggle/enable/disable [i]`: change all or the `i`-th breakpoint\\
        - `bp on/off error/throw`: break on error or throw\\

        Press backspace at an empty prompt to return to the Julia REPL.""")
    return nothing
end

# Turn one line of `debug>` input into the expression that the REPL backend
# should evaluate.
function debug_mode_parse(line::AbstractString)
    stripped = strip(line)
    word = first(split(stripped, r" +"))
    if word == "bp"
        return :($(debug_mode_bp_command)($(String(stripped))))
    elseif word == "?" || word == "help"
        return :($(debug_mode_help)())
    end
    expr = Base.parse_input_line(String(line))
    if isexpr(expr, :toplevel) && length(expr.args) == 2
        expr = expr.args[end]
    end
    if isexpr(expr, :toplevel)
        # A `:toplevel` expression (multiple statements, possibly nested in the
        # outer wrapper unwrapped above, e.g. `x = 1; x + 1`) cannot be spliced
        # into the thunk that `@enter` builds for non-call expressions; a block can
        expr = Expr(:block, expr.args...)
    end
    if expr === nothing || expr isa LineNumberNode ||
       (isexpr(expr, :block) && all(a -> a isa LineNumberNode, expr.args))
        return nothing # empty/whitespace-only input
    end
    if isexpr(expr, :error) || isexpr(expr, :incomplete)
        return expr # let the REPL show the syntax error
    end
    return Expr(:macrocall, var"@enter", LineNumberNode(1, :none), expr)
end

"""
    Debugger.install_repl_mode(repl = Base.active_repl; key = ')')

Install the `debug>` REPL mode, entered by pressing `key` at the beginning of
an empty `julia>` prompt and left with backspace. This is done automatically
when Debugger is loaded in an interactive session.
"""
function install_repl_mode(repl = Base.active_repl; key::Char = ')')
    repl isa REPL.LineEditREPL || error("expected a LineEditREPL")
    isdefined(repl, :interface) || (repl.interface = REPL.setup_interface(repl))
    main_mode = repl.interface.modes[1]

    # Already installed?
    for mode in repl.interface.modes
        mode isa LineEdit.Prompt && mode.prompt == DEBUG_MODE_PROMPT && return mode
    end

    debug_mode = LineEdit.Prompt(DEBUG_MODE_PROMPT;
        prompt_prefix = Sys.iswindows() ? "\e[33m" : "\e[38;5;166m",
        prompt_suffix = repl.envcolors ? Base.input_color : repl.input_color,
        complete = REPL.REPLCompletionProvider(),
        on_enter = REPL.return_callback,
        sticky = true)

    hp = main_mode.hist
    hp.mode_mapping[:debug] = debug_mode
    debug_mode.hist = hp

    debug_mode.on_done = REPL.respond(debug_mode_parse, repl, main_mode)

    mk = REPL.mode_keymap(main_mode)
    debug_mode.keymap_dict = LineEdit.keymap(Dict{Any,Any}[
        mk, LineEdit.history_keymap, LineEdit.default_keymap, LineEdit.escape_defaults])

    push!(repl.interface.modes, debug_mode)

    enter_debug_mode = function (s, args...)
        if isempty(s) || position(LineEdit.buffer(s)) == 0
            buf = copy(LineEdit.buffer(s))
            LineEdit.transition(s, debug_mode) do
                LineEdit.state(s, debug_mode).input_buffer = buf
            end
        else
            LineEdit.edit_insert(s, key)
        end
    end
    main_mode.keymap_dict = LineEdit.keymap_merge(main_mode.keymap_dict,
        Dict{Any,Any}(key => enter_debug_mode))

    return debug_mode
end

function auto_install_repl_mode()
    if isdefined(Base, :active_repl) && Base.active_repl isa REPL.LineEditREPL
        try
            install_repl_mode(Base.active_repl)
        catch err
            @warn "Failed to install the `debug>` REPL mode" exception=(err, catch_backtrace())
        end
    else
        atreplinit() do repl
            repl isa REPL.LineEditREPL || return
            try
                install_repl_mode(repl)
            catch err
                @warn "Failed to install the `debug>` REPL mode" exception=(err, catch_backtrace())
            end
        end
    end
    return nothing
end
