
function assert_is_toplevel_frame(state)
    state.level == 1 && return true
    printstyled(stderr, "Cannot step in a non toplevel frame,\n"; color=:red)
    return false
end

function execute_command(state::DebuggerState, ::Union{Val{:nc},Val{:n},Val{:se},Val{:s},Val{:si},Val{:sg},Val{:finish}}, cmd::AbstractString)
    assert_is_toplevel_frame(state) || return false
    ret = JuliaInterpreter.debug_command(JuliaInterpreter.finish_and_return!, state.frame, cmd)
    if ret === nothing
        state.overall_result = JuliaInterpreter.get_return(state.frame)
        state.frame == nothing
    else
        state.frame, pc = ret
    end
    return true
end

function execute_command(state::DebuggerState, ::Val{:bt}, cmd)
    num = 0
    frame = state.frame
    while frame !== nothing
        num += 1
        print_frame(Base.pipe_writer(state.terminal), num, frame)
        frame = frame.caller
    end
    println()
    return false
end

function execute_command(state::DebuggerState, ::Union{Val{:f},Val{:fr}}, cmd)
    subcmds = split(cmd,' ')[2:end]
    if isempty(subcmds) || subcmds[1] == "v"
        print_frame(Base.pipe_writer(state.terminal), state.level, active_frame(state))
        return false
    else
        new_level = parse(Int, subcmds[1])
        if new_level > length(state.stack) || new_level < 1
            printstyled(stderr, "Not a valid frame index\n"; color=:red)
            return false
        end
        state.level = new_level
    end
    return true
end

function execute_command(state::DebuggerState, _, cmd)
    println("Unknown command `$cmd`. Executing `?` to obtain help.")
    execute_command(state, Val{Symbol("?")}(), "?")
end

function execute_command(state::DebuggerState, ::Val{:?}, cmd::AbstractString)
    display(
            @md_str """
    Basic Commands:\\
    - `n` steps to the next line\\
    - `s` steps into the next call\\
    - `finish` runs to the end of the function\\
    - `bt` shows a simple backtrace\\
    - ``` `stuff ``` runs `stuff` in the current frame's context\\
    - `fr v` will show all variables in the current frame\\
    - `f n` where `n` is an integer, will go to the `n`-th frame\\
    - `q` quits the debugger, returning `nothing`\\
    Advanced commands:\\
    - `nc` steps to the next call\\
    - `se` does one expression step\\
    - `si` does the same but steps into a call if a call is the next expression\\
    - `sg` steps into a generated function\\
    """)
    return false
end
