
function assert_allow_step(state)
    if state.broke_on_error
        printstyled(stderr, "Cannot step after breaking on error\n"; color=Base.error_color())
        return false
    end
    if state.level != 1
        printstyled(stderr, "Cannot step in a non leaf frame\n"; color=Base.error_color())
        return false
    end
    return true
end

invalid_command(state, cmd) = execute_command(state, Val(:_), cmd) # print error

function show_breakpoint(io::IO, bp::BreakpointRef, state::DebuggerState)
    outbuf = IOContext(IOBuffer(), io)
    if bp.err === nothing
        print(outbuf, "Hit breakpoint:\n")
    else
        print(outbuf, "Breaking for error:\n")
        Base.display_error(outbuf, bp.err, state.frame)
        println(outbuf)
    end
    print(io, String(take!(outbuf.io)))
end

function execute_command(state::DebuggerState, v::Union{Val{:c},Val{:nc},Val{:n},Val{:se},Val{:s},Val{:si},Val{:sg},Val{:so},Val{:u},Val{:sl},Val{:sr}}, cmd::AbstractString)
    # These commands take no arguments
    kwargs = Dict()
    if v != Val(:u)
        length(split(cmd, r" +")) == 1 || return invalid_command(state, cmd)
    else
        args = split(cmd, r" +")
        length(args) > 2 && return invalid_command(state, cmd)
        cmd = args[1]
        if length(args) == 2
            line = tryparse(Int, args[2])
            line === nothing && return invalid_command(state, cmd)
            kwargs = Dict(:line => line)
        end
    end
    assert_allow_step(state) || return false
    cmd == "so" && (cmd = "finish")
    cmd == "u" && (cmd = "until")
    ret = debug_command(state.mode, state.frame, Symbol(cmd); kwargs...)
    if ret === nothing
        state.overall_result = get_return(root(state.frame))
        state.frame = nothing
        return false
    else
        state.frame, pc = ret
        if pc isa BreakpointRef
            if pc.stmtidx != 0 # This is the dummy breakpoint to stop just after entering a call
                if state.terminal !== nothing # fix this, it happens when a test hits this and hasnt set a terminal
                    show_breakpoint(Base.pipe_writer(state.terminal), pc, state)
                end
            end
            if pc.err !== nothing
                state.broke_on_error = true
            end
        end
        if pc_expr(state.frame) === nothing # happens when stopping for @bp
            JuliaInterpreter.maybe_next_call!(state.frame)
        end
        return true
    end
end

function execute_command(state::DebuggerState, ::Val{:bt}, cmd)
    io = Base.pipe_writer(state.terminal)
    iob = IOContext(IOBuffer(), io)
    num = 0
    frame = state.frame
    while frame !== nothing
        num += 1
        print_frame(iob, num, frame; current_line=true)
        frame = caller(frame)
    end
    print(io, String(take!(iob.io)))
    return false
end

function stacklength(frame)
    s = 0
    while frame !== nothing
        s += 1
        frame = caller(frame)
    end
    return s
end

execute_command(state::DebuggerState, ::Val{:st}, cmd) = true

function execute_command(state::DebuggerState, ::Union{Val{:f}, Val{:fr}}, cmd)
    subcmds = split(cmd, r" +")
    if length(subcmds) == 1
        if cmd == "f"
            new_level = 1
        else
            new_level = state.level
        end
    else
        new_level = tryparse(Int, subcmds[2])
        if new_level == nothing
            printstyled(stderr, "Failed to parse $(repr(subcmds[2])) as an integer\n"; color=Base.error_color())
            return false
        end
    end

    if new_level > stacklength(state.frame) || new_level < 1
        printstyled(stderr, "Not a valid frame index\n"; color=Base.error_color())
        return false
    end

    if subcmds[1] == "fr"
        old_level = state.level
        try
            state.level = new_level
            print_frame(Base.pipe_writer(state.terminal), new_level, active_frame(state))
        finally
            state.level = old_level
        end
        return false
    else
        state.level = new_level
        return true
    end
end

function execute_command(state::DebuggerState, v::Union{Val{:up}, Val{:down}}, cmd::AbstractString)
    args = split(cmd, r" +")[2:end]
    if isempty(args)
        offset = v == Val(:up) ? +1 : -1
    else
        length(args) > 1 && return invalid_command(state, cmd)
        offset = tryparse(Int, args[1])
        offset == nothing && return invalid_command(state, cmd)
        v == Val(:down) && (offset *= -1)
    end
    return execute_command(state, Val(:f), string("f ", state.level + offset))
end
function execute_command(state::DebuggerState, ::Val{:w}, cmd::AbstractString)
    # TODO show some info messages?
    cmds = split(cmd, r" +")
    success_and_show = false
    if length(cmds) == 1
        success_and_show = true
    elseif length(cmds) >= 2
        if cmds[2] == "rm"
            if length(cmds) == 2
                clear_watch_list!(state)
                success_and_show = true
            elseif length(cmds) == 3
                i = tryparse(Int, cmds[3])
                if i !== nothing
                    clear_watch_list!(state, i)
                    success_and_show = true
                end
            end
        end
        if cmds[2] == "add"
            success_and_show = add_watch_entry!(state, join(cmds[3:end]))
        end
    end
    if success_and_show
        io = Base.pipe_writer(state.terminal)
        outbuf = IOContext(IOBuffer(), io)
        show_watch_list(outbuf, state)
        print(io, String(take!(outbuf.io)))
        println(io)
        return false
    end
    # Error
    return invalid_command(state, cmd)
end

function execute_command(state::DebuggerState, v::Union{Val{:bp}}, cmd::AbstractString)
    cmds = split(cmd, r" +")
    function repl_show_breakpoints()
        if state.terminal !== nothing
            io = Base.pipe_writer(state.terminal)
            outbuf = IOContext(IOBuffer(), io)
            show_breakpoints(outbuf, state)
            print(io, String(take!(outbuf.io)))
        end
    end
    if length(cmds) == 1
        repl_show_breakpoints()
        return false
    else
        if cmds[2] == "add"
            ok = add_breakpoint!(state, join(cmds[3:end], ' '))
            ok && repl_show_breakpoints()
            return false
        elseif length(cmds) == 2 || length(cmds) == 3
            if cmds[2] == "on" || cmds[2] == "off"
                break_on_off = cmds[2] == "on" ? JuliaInterpreter.break_on : JuliaInterpreter.break_off
                s = length(cmds) == 3 ? Symbol(cmds[3]) : :error
                if s == :error || s == :throw
                    break_on_off(s)
                    repl_show_breakpoints()
                    return false
                end
            elseif cmds[2] == "rm" || cmds[2] == "toggle" || cmds[2] == "disable" || cmds[2] == "enable"
                i = missing
                if length(cmds) == 3
                    i = tryparse(Int, cmds[3])
                end
                if i !== nothing
                    ok = begin
                        cmds[2] == "rm"      ? (i === missing ? remove_breakpoint!(state)  :  remove_breakpoint!(state, i)) :
                        cmds[2] == "toggle"  ? (i === missing ? toggle_breakpoint!(state)  :  toggle_breakpoint!(state, i)) :
                        cmds[2] == "disable" ? (i === missing ? disable_breakpoint!(state) :  disable_breakpoint!(state, i)) :
                        cmds[2] == "enable"  ? (i === missing ? enable_breakpoint!(state)  :  enable_breakpoint!(state, i)) :
                        true
                    end
                    ok && repl_show_breakpoints()
                    return false
                end
            end
        end
    end

    # Error
    return invalid_command(state, cmd)
end


function execute_command(state::DebuggerState, _, cmd)
    display(Markdown.parse("""Unknown command `$cmd`. Run `?` to obtain help."""))
    return false
end

function execute_command(state::DebuggerState, ::Union{Val{:help}, Val{:?}}, cmd::AbstractString)
    display(
            @md_str """
            # Debugger commands
            Below, square brackets denote optional arguments.

            Misc:\\
            - `o`: open the current line in an editor\\
            - `q`: quit the debugger, returning `nothing`\\
            - `C`: toggle compiled mode\\
            - `L`: toggle showing lowered code instead of source code\\
            - `+`/`-`: increase / decrease the number of lines of source code shown\\


            Stepping (basic):\\
            - `n`: step to the next line\\
            - `u [i::Int]`: step until line `i` or the next line past the current line\\
            - `s`: step into the next call\\
            - `so`: step out of the current call\\
            - `sl`: step into the last call on the current line (e.g. steps into `f` if the line is `f(g(h(x)))`).\\
            - `sr`: step until next `return`.\\
            - `c`: continue execution until a breakpoint is hit\\
            - `f [i::Int]`: go to the `i`-th function in the call stack (stepping is only possible in the function at the top of the call stack)\\
            - `up/down [i::Int]` go up or down one or `i` functions in the call stack\\


            Stepping (advanced):\\
            - `nc`: step to the next call\\
            - `se`: step one expression step\\
            - `si`: same as `se` but step into a call if a call is the next expression\\
            - `sg`: step into a generated function\\


            Querying:\\
            - `st`: show the "status" (current function, source code and current expression to run)\\
            - `bt`: show a backtrace\\
            - `fr [i::Int]`: show all variables in the current or `i`th frame\\


            Evaluation:\\
            - `w`\\
                - `w add expr`: add an expression to the watch list\\
                - `w`: show all watch expressions evaluated in the current function's context\\
                - `w rm [i::Int]`: remove all or the `i`:th watch expression\\


            Breakpoints:\\
            - `bp add`\\
                - `bp add "file.jl":line [cond]`: add a breakpoint att file `file.jl` on line `line` with condition `cond`\\
                - `bp add func [:line] [cond]`: add a breakpoint to function `func` at line `line` (defaulting to first line)  with condition `cond`\\
                - `bp add func(::Float64, Int)[:line] [cond]`: add a breakpoint to methods matching the signature at line `line` (defaulting to first line)  with condition `cond`\\
                - `bp add func(x, y)[:line] [cond]`: add a breakpoint to the method matching the types of the local variable `x`, `y` etc with condition `cond`\\
                - `bp add line [cond]` add a breakpoint to `line` of the file of the current function  with condition `cond`\\
            - `bp` show all breakpoints\\
            - `bp rm [i::Int]`: remove all or the `i`:th breakpoint\\
            - `bp toggle [i::Int]`: toggle all or the `i`:th breakpoint\\
            - `bp disable [i::Int]`: disable all or the `i`:th breakpoint\\
            - `bp enable [i::Int]`: enable all or the `i`:th breakpoint\\
            - `bp on/off`\\
                - `bp on/off error` - turn on or off break on error\\
                - `bp on/off throw` - turn on or off break on throw\\


            An empty command will execute the previous command.

            Hit `` ` `` to enter "evaluation mode," where any expression you type is executed in the debug context.
            Hit backspace as the first character of the line (or `^C` anywhere) to return to "debug mode." """)
    return false
end

function execute_command(state::DebuggerState, ::Val{:o}, cmd::AbstractString)
    frame = active_frame(state)
    loc = JuliaInterpreter.whereis(frame)
    if loc === nothing
        printstyled(stderr, "Could not find source location\n"; color=Base.error_color())
        return false
    end
    file, line = loc
    if !isfile(file)
        printstyled(stderr, "Could not find file: $(repr(file))\n"; color=Base.error_color())
        return false
    end
    InteractiveUtils.edit(file, line)
    return false
end
