
promptname(level, name) = "$level|$name> "
function RunDebugger(frame, repl = Base.active_repl, terminal = Base.active_repl.t)

    state = DebuggerState(frame, repl, terminal)

    # Setup debug panel
    panel = LineEdit.Prompt(promptname(state.level, "debug");
        prompt_prefix = "\e[38;5;166m",
        prompt_suffix = Base.text_colors[:normal],
        on_enter = s->true)

    panel.hist = REPL.REPLHistoryProvider(Dict{Symbol,Any}(:debug => panel))
    REPL.history_reset_state(panel.hist)

    search_prompt, skeymap = LineEdit.setup_search_keymap(panel.hist)
    search_prompt.complete = REPL.LatexCompletions()

    state.main_mode = panel

    panel.on_done = (s,buf,ok)->begin
        line = String(take!(buf))
        old_level = state.level
        if !ok || strip(line) == "q"
            LineEdit.transition(s, :abort)
            LineEdit.reset_state(s)
            return false
        end
        if isempty(strip(line)) && length(panel.hist.history) > 0
            command = panel.hist.history[end]
        else
            command = strip(line)
        end
        do_print_status = true
        cmd1 = split(command,' ')[1]
        do_print_status = try
            execute_command(state, Val{Symbol(cmd1)}(), command)
        catch err
            rethrow(err)
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
            print_status(Base.pipe_writer(terminal), active_frame(state))
        end
        return true
    end

    key = '`'
    repl_switch = Dict{Any,Any}(
        key => function (s,args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                prompt = julia_prompt(state)
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, prompt) do
                    LineEdit.state(s, prompt).input_buffer = buf
                end
            else
                LineEdit.edit_insert(s,key)
            end
        end
    )

    state.standard_keymap = Dict{Any,Any}[skeymap, LineEdit.history_keymap, LineEdit.default_keymap, LineEdit.escape_defaults]
    panel.keymap_dict = LineEdit.keymap([repl_switch;state.standard_keymap])

    print_status(Base.pipe_writer(terminal), active_frame(state))
    REPL.run_interface(terminal, LineEdit.ModalInterface([panel,search_prompt]))

    return state.overall_result
end


function julia_prompt(state::DebuggerState)
    # Return early if this has already been called on the state
    isassigned(state.julia_prompt) && return state.julia_prompt[]

    julia_prompt = LineEdit.Prompt(promptname(state.level, "julia");
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
        xbuf = copy(buf)
        command = String(take!(buf))
        @static if VERSION >= v"1.2.0-DEV.253"
            response = _eval_code(active_frame(state), command)
            REPL.print_response(state.repl, response, true, true)
        else
            ok, result = _eval_code(active_frame(state), command)
            REPL.print_response(state.repl, ok ? result : result[1], ok ? nothing : result[2], true, true)
        end
        println(state.terminal)
        LineEdit.reset_state(s)
    end
    julia_prompt.keymap_dict = LineEdit.keymap([REPL.mode_keymap(state.main_mode); state.standard_keymap])
    state.julia_prompt[] = julia_prompt
    return julia_prompt
end

@static if VERSION >= v"1.2.0-DEV.253"
    function _eval_code(frame::Frame, code::AbstractString)
        try
            return eval_code(frame, code), false
        catch
            return Base.catch_stack(), true
        end
    end
else
    function _eval_code(frame::Frame, code::AbstractString)
        try
            return true, eval_code(frame, code)
        catch err
            return false, (err, catch_backtrace())
        end
    end
end

function eval_code(frame::Frame, command::AbstractString)
    expr = Base.parse_input_line(command)
    isexpr(expr, :toplevel) && (expr = expr.args[end])
    # see https://github.com/JuliaLang/julia/issues/31255 for the Symbol("") check
    vars = filter(v -> v.name != Symbol(""), JuliaInterpreter.locals(frame))
    res = gensym()
    eval_expr = Expr(:let,
        Expr(:block, map(x->Expr(:(=), x...), [(v.name, v.value) for v in vars])...),
        Expr(:block,
            Expr(:(=), res, expr),
            Expr(:tuple, res, Expr(:tuple, [v.name for v in vars]...))
        ))
    eval_res, res = Core.eval(moduleof(frame), eval_expr)
    j = 1
    for (i, v) in enumerate(vars)
        if v.isparam
            frame.sparams[j] = res[i]
            j += 1
        else
            frame.framedata.locals[frame.framedata.last_reference[v.name]] = Some{Any}(res[i])
        end
    end
    eval_res
end

# Completions

mutable struct DebugCompletionProvider <: REPL.CompletionProvider
    state::DebuggerState
end

function LineEdit.complete_line(c::DebugCompletionProvider, s)
    partial = REPL.beforecursor(s.input_buffer)
    full = LineEdit.input_string(s)
    ret, range, should_complete = completions(c, full, lastindex(partial))
    return unique!(map(REPLCompletions.completion_text, ret)), partial[range], should_complete
end

function completions(c::DebugCompletionProvider, full, partial)
    mod = moduleof(c.state.frame)
    ret, range, should_complete = REPLCompletions.completions(full, partial, mod)

    # TODO Add local variable completions
    return ret, range, should_complete
end
