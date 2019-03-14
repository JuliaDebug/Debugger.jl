
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

function execute_command(state::DebuggerState, ::Union{Val{:c},Val{:nc},Val{:n},Val{:se},Val{:s},Val{:si},Val{:sg},Val{:so}}, cmd::AbstractString)
    assert_allow_step(state) || return false
    cmd == "so" && (cmd = "finish")
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
        JuliaInterpreter.maybe_next_call!(state.frame)
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

execute_command(state::DebuggerState, ::Val{:st}, cmd) = true

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
    - `st`: show the status\\
    - `n`: step to the next line\\
    - `s`: step into the next call\\
    - `so`: step out of the current call\\
    - `c`: continue execution until a breakpoint is hit\\
    - `bt`: show a simple backtrace\\
    - ``` `stuff ```: run `stuff` in the current function's context\\
    - `fr [v::Int]`: show all variables in the current frame, `v` defaults to `1`\\
    - `f [n::Int]`: go to the `n`-th frame\\
    - `q`: quit the debugger, returning `nothing`\\
    Advanced commands:\\
    - `nc`: step to the next call\\
    - `se`: step one expression step\\
    - `si`: same as `se` but step into a call if a call is the next expression\\
    - `sg`: step into a generated function\\
    """)
    return false
end
