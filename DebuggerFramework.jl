__precompile__()
module DebuggerFramework
    using TerminalUI

    abstract type StackFrame end

    function print_var(io::IO, name, val::Nullable, undef_callback)
        print("  | ")
        if isnull(val)
            @assert false
        else
            val = get(val)
            T = typeof(val)
            val = repr(val)
            if length(val) > 150
                val = Suppressed("$(length(val)) bytes of output")
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
        main_mode
        terminal
    end

    function print_status_synthtic(io, state, frame, lines_before, total_lines)
        return 0
    end

    haslocinfo(frame) = false
    locdesc(frame) = "unknown function"

    print_status(io, state) = print_status(io, state, state.stack[state.level])
    function print_status(io, state, frame)
        # Buffer to avoid flickering
        outbuf = IOBuffer()
        print_with_color(:bold, outbuf, "In ", locdesc(frame), "\n")
        if haslocinfo(frame)
            # Print location here
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
        print(io, String(take!(outbuf)))
    end

    struct AbstractDiagnostic; end

    function execute_command
    end

    using Base: LineEdit, REPL
    function RunDebugger(stack, terminal = Base.active_repl.t)
      promptname(level, name) = "$level|$name > "

      repl = Base.active_repl
      state = DebuggerState(stack, 1, nothing, terminal)

      # Setup debug panel
      panel = LineEdit.Prompt(promptname(state.level, "debug");
          prompt_prefix="\e[38;5;166m",
          prompt_suffix=Base.text_colors[:white],
          on_enter = s->true)

      # For now use the regular REPL completion provider
      replc = Base.REPL.REPLCompletionProvider()


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
              isa(err, AbstractDiagnostic) || rethrow(err)
              caught = false
              for interp_idx in length(state.top_interp.stack):-1:1
                  if process_exception!(state.top_interp.stack[interp_idx], err, interp_idx == length(top_interp.stack))
                      interp = state.top_interp = state.top_interp.stack[interp_idx]
                      resize!(state.top_interp.stack, interp_idx)
                      caught = true
                      break
                  end
              end
              !caught && rethrow(err)
              display_diagnostic(STDERR, state.interp.code, err)
              println(STDERR)
              LineEdit.reset_state(s)
              return true
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

      const all_commands = ("q", "s", "si", "finish", "bt", "loc", "ind", "shadow",
          "up", "down", "ns", "nc", "n", "se")

      const repl_switch = Dict{Any,Any}(
          '`' => function (s,args...)
              if isempty(s) || position(LineEdit.buffer(s)) == 0
                  prompt = language_specific_prompt(state, state.interp)
                  buf = copy(LineEdit.buffer(s))
                  LineEdit.transition(s, prompt) do
                      LineEdit.state(s, prompt).input_buffer = buf
                  end
              else
                  LineEdit.edit_insert(s,key)
              end
          end
      )

      b = Dict{Any,Any}[skeymap, LineEdit.history_keymap, LineEdit.default_keymap, LineEdit.escape_defaults]
      panel.keymap_dict = LineEdit.keymap([repl_switch;b])

      # Skip evaluated values (e.g. constants)
      print_status(Base.pipe_writer(terminal), state)
      Base.REPL.run_interface(terminal, LineEdit.ModalInterface([panel,search_prompt]))
    end

end # module
