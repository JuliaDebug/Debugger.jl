__precompile__()
module DebuggerFramework
    include("LineNumbers.jl")
    using .LineNumbers: SourceFile, compute_line

    abstract type StackFrame end

    struct Suppressed{T}
        item::T
    end
    Base.show(io::IO, x::Suppressed) = print(io, "<suppressed ", x.item, '>')

    function print_var(io::IO, name, val::Nullable, undef_callback)
        print("  | ")
        if isnull(val)
            @assert false
        else
            val = get(val)
            T = typeof(val)
            try
                val = repr(val)
                if length(val) > 150
                    val = Suppressed("$(length(val)) bytes of output")
                end
            catch
                val = Suppressed("printing error")
            end
            println(io, name, "::", T, " = ", val)
        end
    end

    function print_locals(io::IO, args...)
    end

    print_locdesc(io, frame) = println(io, locdesc(frame))
    function print_frame(_, io::IO, num, frame)
        print(io, "[$num] ")
        print_locdesc(io, frame)
        print_locals(io, frame)
    end

    function print_backtrace(state)
        for (num, frame) in enumerate(state.stack)
            print_frame(state, Base.pipe_writer(state.terminal), num, frame)
        end
    end

    print_backtrace(state, _::Void) = nothing

    function execute_command(state, frame, ::Val{:bt}, cmd)
        print_backtrace(state)
        println()
        return false
    end

    function execute_command(state, frame, ::Val{Symbol("?")}, cmd)
        println("Help not implemented for this debugger.")
        return false
    end

    function execute_command(state, frame, _, cmd)
        println("Unknown command `$cmd`. Executing `?` to obtain help.")
        execute_command(state, frame, Val{Symbol("?")}(), "?")
    end

    function execute_command(state, interp, ::Union{Val{:f},Val{:fr}}, command)
        subcmds = split(command,' ')[2:end]
        if isempty(subcmds) || subcmds[1] == "v"
            print_frame(state, Base.pipe_writer(state.terminal), state.level, state.stack[state.level])
            return false
        else
            new_level = parse(Int, subcmds[1])
            new_stack_idx = length(state.stack)-(new_level-1)
            if new_stack_idx > length(state.stack) || new_stack_idx < 1
                print_with_color(:red, STDERR, "Not a valid frame index\n")
                return false
            end
            state.level = new_level
        end
        return true
    end

    """
      Start debugging the specified code in the the specified environment.
      The second argument should default to the global environment if such
      an environment exists for the language in question.
    """
    function debug
    end

    mutable struct DebuggerState
        stack
        level
        repl
        main_mode
        language_modes
        standard_keymap
        terminal
        overall_result
    end
    dummy_state(stack) = DebuggerState(stack, 1, nothing, nothing, nothing, nothing, nothing, nothing)

    function print_status_synthtic(io, state, frame, lines_before, total_lines)
        return 0
    end

    struct FileLocInfo
        filepath::String
        line::Int
        # 0 if unknown
        column::Int
        # The line at which the current context starts, 0 if unknown
        defline::Int
    end

    struct BufferLocInfo
        data::String
        line::Int
        # 0 if unknown
        column::Int
        defline::Int
    end

    locinfo(frame) = nothing
    locdesc(frame) = "unknown function"

    """
    Determine the offsets in the source code to print, based on the offset of the
    currently highlighted part of the code, and the start and stop line of the
    entire function.
    """
    function compute_source_offsets(code, offset, startline, stopline; file = SourceFile(code))
        offsetline = compute_line(file, offset)
        if offsetline - 3 > length(file.offsets) || startline > length(file.offsets)
            return -1, -1
        end
        startoffset = max(file.offsets[max(offsetline-3,1)], file.offsets[startline])
        stopoffset = endof(code)-1
        if offsetline + 3 < endof(file.offsets)
            stopoffset = min(stopoffset, file.offsets[offsetline + 3]-1)
        end
        if stopline + 1 < endof(file.offsets)
            stopoffset = min(stopoffset, file.offsets[stopline + 1]-1)
        end
        startoffset, stopoffset
    end

    function print_sourcecode(io, code, line, defline; file = SourceFile(code))
        startoffset, stopoffset = compute_source_offsets(code, file.offsets[line], defline, line+3; file=file)

        if startoffset == -1
            print_with_color(:bold, io, "Line out of file range (bad debug info?)")
            return
        end

        # Compute necessary data for line numbering
        startline = compute_line(file, startoffset)
        stopline = compute_line(file, stopoffset)
        current_line = line
        stoplinelength = length(string(stopline))

        code = split(code[(startoffset+1):(stopoffset+1)],'\n')
        lineno = startline

        if !isempty(code) && isempty(code[end])
            pop!(code)
        end

        for textline in code
            print_with_color(lineno == current_line ? :yellow : :bold, io,
                string(lineno, " "^(stoplinelength-length(lineno)+1)))
            println(io, textline)
            lineno += 1
        end
        println(io)
    end

    print_next_state(outbuf::IO, state, frame) = nothing

    print_status(io, state) = print_status(io, state, state.stack[state.level])
    function print_status(io, state, frame)
        # Buffer to avoid flickering
        outbuf = IOBuffer()
        print_with_color(:bold, outbuf, "In ", locdesc(frame), "\n")
        loc = locinfo(frame)
        if loc !== nothing
            data = if isa(loc, BufferLocInfo)
                    loc.data
                else
                    VERSION < v"0.7" ? readstring(loc.filepath) :
                    read(loc.filepath, String)
                end
            print_sourcecode(outbuf, data,
                loc.line, loc.defline)
        else
            buf = IOBuffer()
            active_line = print_status_synthtic(buf, state, frame, 2, 5)::Int
            code = split(String(take!(buf)),'\n')
            @assert active_line <= length(code)
            for (lineno, line) in enumerate(code)
                if lineno == active_line
                    print_with_color(:yellow, outbuf, "=> ", bold = true); println(outbuf, line)
                else
                    print_with_color(:bold, outbuf, "?  "); println(outbuf, line)
                end
            end
        end
        print_next_state(outbuf, state, frame)
        print(io, String(take!(outbuf)))
    end

    abstract type AbstractDiagnostic; end

    function execute_command
    end

    function language_specific_prompt
    end

    function eval_code(state, frame, code)
        error("Code evaluation not implemented for this debugger")
    end

    function eval_code(state, code)
        try
            result = eval_code(state, state.stack[1], code)
            true, result
        catch err
            bt = catch_backtrace()
            false, (err, bt)
        end
    end

    using Base: LineEdit, REPL
    promptname(level, name) = "$level|$name > "
    function RunDebugger(stack, repl = Base.active_repl, terminal = Base.active_repl.t)

        state = DebuggerState(stack, 1, repl, nothing, Dict{Symbol, Any}(), nothing, terminal, nothing)

        # Setup debug panel
        panel = LineEdit.Prompt(promptname(state.level, "debug");
            prompt_prefix="\e[38;5;166m",
            prompt_suffix=Base.text_colors[:white],
            on_enter = s->true)

        # 0.7 compat
        if isdefined(panel, :repl)
            panel.repl = repl
        end
        panel.hist = REPL.REPLHistoryProvider(Dict{Symbol,Any}(:debug => panel))
        Base.REPL.history_reset_state(panel.hist)

        search_prompt, skeymap = Base.LineEdit.setup_search_keymap(panel.hist)
        search_prompt.complete = Base.REPL.LatexCompletions()

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
                execute_command(state, state.stack[state.level], Val{Symbol(cmd1)}(), command)
            catch err
                rethrow(err)
            end
            if old_level != state.level
                panel.prompt = promptname(state.level,"debug")
            end
            LineEdit.reset_state(s)
            if isempty(state.stack)
                LineEdit.transition(s, :abort)
                LineEdit.reset_state(s)
                return false
            end
            if do_print_status
                print_status(Base.pipe_writer(terminal), state)
            end
            return true
        end

        key = '`'
        repl_switch = Dict{Any,Any}(
            key => function (s,args...)
                if isempty(s) || position(LineEdit.buffer(s)) == 0
                    prompt = language_specific_prompt(state, state.stack[1])
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

        print_status(Base.pipe_writer(terminal), state)
        Base.REPL.run_interface(terminal, LineEdit.ModalInterface([panel,search_prompt]))

        state.overall_result
    end

end # module
