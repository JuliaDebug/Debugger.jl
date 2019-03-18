
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
    code = bp.framecode
    if code.scope isa Method
        scope_str = sprint(locdesc, code)
    else
        scope_str = repr(code.scope)
    end
    if checkbounds(Bool, bp.framecode.breakpoints, bp.stmtidx)
        lineno = linenumber(bp.framecode, bp.stmtidx)
        print(outbuf, scope_str, ", line ", lineno)
    else
        print(outbuf, scope_str, ", %", bp.stmtidx)
    end
    if bp.err !== nothing
        print(outbuf, ", ", bp.err)
    end
    print(io, String(take!(outbuf.io)))
    println(io)
end

const always_run_recursive_interpret = Ref(false)
no_chance_of_breaking() = isempty(JuliaInterpreter._breakpoints) && !JuliaInterpreter.break_on_error[]
function run_in_compiled()
    return no_chance_of_breaking() && !(always_run_recursive_interpret[])
end

function execute_command(state::DebuggerState, ::Union{Val{:c},Val{:nc},Val{:n},Val{:se},Val{:s},Val{:si},Val{:sg},Val{:so}}, cmd::AbstractString)
    assert_allow_step(state) || return false
    cmd == "so" && (cmd = "finish")
    mode = run_in_compiled() ? Compiled() : finish_and_return!
    ret = debug_command(mode, state.frame, Symbol(cmd))
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

function execute_command(state::DebuggerState, ::Val{:w}, cmd::AbstractString)
    # TODO show some info messages?
    cmds = split(cmd)
    if length(cmds) == 1
        io = Base.pipe_writer(state.terminal)
        show_watch_list(io, state)
        return false
    elseif length(cmds) >= 2
        if cmds[2] == "rm"
            if length(cmds) == 2
                clear_watch_list!(state)
                return false
            elseif length(cmds) == 3
                i = parse(Int, cmds[3])
                clear_watch_list!(state, i)
                return false
            end
        end
        if cmds[2] == "add"
            if add_watch_entry!(state, join(cmds[3:end]))
            end
            return false
        end
    end
    # Error
    return execute_command(state, Val(:_), cmd)
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
    - `w`\\
        - `w add expr`: add an expression to the watch list\\
        - `w`: show all watch expressions evaluated in the current function's context\\
        - `w rm [i::Int]`: remove all or the `i`:th watch expression\\
    - `q`: quit the debugger, returning `nothing`\\
    Advanced commands:\\
    - `nc`: step to the next call\\
    - `se`: step one expression step\\
    - `si`: same as `se` but step into a call if a call is the next expression\\
    - `sg`: step into a generated function\\
    """)
    return false
end
