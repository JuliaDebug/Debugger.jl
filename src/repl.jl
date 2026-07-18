
promptname(level, name) = "$level|$name> "

function write_prompt(terminal, mode)
    LineEdit.write_prompt(terminal, mode, LineEdit.hascolor(terminal))
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
            # This will only show the stacktrace up to the current frame because
            # currently, the unwinding in JuliaInterpreter unlinks the frames to
            # where the error is thrown

            # Buffer error printing
            io = IOContext(IOBuffer(), output_stream(state))
            Base.display_error(io, err, JuliaInterpreter.leaf(state.frame))
            print(output_stream(state), String(take!(io.io)))
            # Comment below out if you are debugging the Debugger
            #Base.display_error(Base.pipe_writer(terminal), err, catch_backtrace())
            LineEdit.transition(s, :abort)
            LineEdit.reset_state(s)
           return false
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
            print_status(output_stream(state), active_frame(state); force_lowered = state.lowered_status)
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
                print_status(output_stream(state), active_frame(state); force_lowered=state.lowered_status)
                write_prompt(state.terminal, panel)
            else
                LineEdit.edit_insert(s, "L")
            end
        end,
        '+' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                NUM_SOURCE_LINES_UP_DOWN[] += 1
                println(output_stream(state))
                print_status(output_stream(state), active_frame(state); force_lowered=state.lowered_status)
                write_prompt(state.terminal, panel)
            else
                LineEdit.edit_insert(s, "+")
            end
        end,
        '-' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                NUM_SOURCE_LINES_UP_DOWN[] = max(1, NUM_SOURCE_LINES_UP_DOWN[] - 1)
                println(output_stream(state))
                print_status(output_stream(state), active_frame(state); force_lowered=state.lowered_status)
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

    # If a breakpoint is set on the statement we are already stopped at, `c` would
    # step over it, so stay put and show the prompt instead (#134)
    if initial_continue && !JuliaInterpreter.shouldbreak(state.frame, state.frame.pc)
        try
            execute_command(state, Val(:c), "c")
        catch err
            # Buffer error printing
            io = IOContext(IOBuffer(), output_stream(state))
            Base.display_error(io, err, JuliaInterpreter.leaf(state.frame))
            print(output_stream(state), String(take!(io.io)))
            return
        end
        state.frame === nothing && return state.overall_result
    end
    if pc_expr(state.frame) === nothing
        JuliaInterpreter.maybe_next_call!(state.frame)
    end
    print_status(output_stream(state), active_frame(state); force_lowered=state.lowered_status)

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
        return Base.catch_stack(), true
    end
end

# Completions

mutable struct DebugCompletionProvider <: REPL.CompletionProvider
    state::DebuggerState
end

function LineEdit.complete_line(c::DebugCompletionProvider, s; hint=true)
    partial = REPL.beforecursor(s.input_buffer)
    full = LineEdit.input_string(s)

    ret, range, should_complete = completions(c, full, partial)
    return ret, partial[range], should_complete
end

function completions(c::DebugCompletionProvider, full, partial)
    frame = c.state.frame

    # repl backend completions
    comps1, range1, should_complete1 = REPLCompletions.completions(full, lastindex(partial), moduleof(frame))
    ret1 = map(REPLCompletions.completion_text, comps1)

    ignore_local(v) = v.name == Symbol("#self") && (v.value isa Type || sizeof(v.value) == 0)
    m = Module()
    for v in locals(frame)
        ignore_local(v) && continue
        Base.eval(m, :($(v.name) = $(QuoteNode(v.value))))
    end

    comps2, range2, should_complete2 = Base.invokelatest(REPLCompletions.completions, full, lastindex(partial), m)
    ret2 = map(REPLCompletions.completion_text, comps2)

    ret = sort!(unique!(vcat(ret1, ret2)))
    should_complete = should_complete1 | should_complete2
    range = min(range1, range2) # Not sure about this one

    # Attempt to allow values to be garbage collected
    # because I don't think Julia ever GCs modules.
    for v in locals(frame)
        ignore_local(v) && continue
        Base.eval(m, :($(v.name) = nothing))
    end

    ret, range, should_complete
end
