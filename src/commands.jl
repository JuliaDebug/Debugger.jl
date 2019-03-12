
function assert_allow_step(state)
    if state.broke_on_error
        printstyled(stderr, "Cannot step after breaking on error\n"; color=:red)
        return false
    end
    if state.level != 1
        printstyled(stderr, "Cannot step in a non leaf frame\n"; color=:red)
        return false
    end
    return true
end

function show_breakpoint(io::IO, bp::BreakpointRef)
    outbuf = IOContext(IOBuffer(), io)
    if bp.err === nothing
        print(outbuf, "Hit breakpoint: ")
    else
        print(outbuf, "Breaking on error: ")
    end
    if checkbounds(Bool, bp.framecode.breakpoints, bp.stmtidx)
        lineno = linenumber(bp.framecode, bp.stmtidx)
        print(outbuf, bp.framecode.scope, ", line ", lineno)
    else
        print(outbuf, bp.framecode.scope, ", %", bp.stmtidx)
    end
    if bp.err !== nothing
        print(outbuf, ", ", bp.err)
    end
    print(io, String(take!(outbuf.io)))
    println(io)
end

function execute_command(state::DebuggerState, ::Union{Val{:c},Val{:nc},Val{:n},Val{:se},Val{:s},Val{:si},Val{:sg},Val{:finish}}, cmd::AbstractString)
    assert_allow_step(state) || return false
    ret = debug_command(state.frame, cmd)
    if ret === nothing
        state.overall_result = get_return(root(state.frame))
        state.frame = nothing
        return false
    else
        state.frame, pc = ret
        if pc isa BreakpointRef
            if pc.stmtidx != 0 # This is the dummy breakpoint to stop just after entering a call
                if state.terminal !== nothing # fix this, it happens when a test hits this and hasnt set a terminal
                    show_breakpoint(Base.pipe_writer(state.terminal), pc)
                end
            end
            if pc.err !== nothing
                state.broke_on_error = true
            end
        end
        return true
    end
end

function execute_command(state::DebuggerState, ::Val{:bt}, cmd)
    num = 0
    frame = state.frame
    while frame !== nothing
        num += 1
        print_frame(Base.pipe_writer(state.terminal), num, frame)
        frame = caller(frame)
    end
    println()
    return false
end

function stacklength(frame)
    s = 0
    JuliaInterpreter.traverse(fr -> (s += 1; JuliaInterpreter.caller(fr)), JuliaInterpreter.leaf(frame))
    return s
end

function execute_command(state::DebuggerState, ::Union{Val{:f}, Val{:fr}}, cmd)
    subcmds = split(cmd,' ')[2:end]
    if isempty(subcmds) || subcmds[1] == "v"
        print_frame(Base.pipe_writer(state.terminal), state.level, active_frame(state))
        return false
    else
        new_level = parse(Int, subcmds[1])
        if new_level > stacklength(state.frame) || new_level < 1
            printstyled(stderr, "Not a valid frame index\n"; color=:red)
            return false
        end
        state.level = new_level
        return true
    end
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
    - `c` continue execution until eventually hitting a breakpoint\\
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
