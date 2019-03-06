function perform_return!(state::DebuggerState)
    returning_frame = state.frame
    returning_expr = pc_expr(returning_frame)
    @assert isexpr(returning_expr, :return)
    val = @lookup(returning_frame, returning_expr.args[1])
    if !isempty(state.stack)
        if returning_frame.code.generator
            # Don't do anything here, just return us to where we were
        else
            state.frame = pop!(state.stack)
            prev = pc_expr(state.frame)
            if isexpr(prev, :(=))
                do_assignment!(state.frame, prev.args[1], val)
            elseif isassign(state.frame)
                do_assignment!(state.frame, getlhs(state.frame.pc[]), val)
            end
            state.frame.pc[] += 1
            maybe_next_call!(state.stack, state.frame)
        end
    else
        @assert !returning_frame.code.generator
        state.overall_result = val
    end
    if !isempty(state.stack) && state.frame.code.wrapper
        finish!(state.stack, state.frame)
        perform_return!(state)
    end
end

function propagate_exception!(state::DebuggerState, exc)
    original_stack = copy(state.stack)
    original_frame = state.frame

    # Unwind the stack looking for a frame that catches the exception
    while true
        if !isempty(state.frame.exception_frames)
            # Exception caught
            state.frame.pc[] = JuliaProgramCounter(state.frame.exception_frames[end])
            state.frame.last_exception[] = exc
            return
        end
        isempty(state.stack) && break
        state.frame = pop!(state.stack)
    end

    # Exception not caught
    if JuliaInterpreter.break_on_error[]
        # restore our frame and stack
        state.stack = original_stack
        state.frame = original_frame
        push!(state.stack, state.frame)
        return JuliaInterpreter.BreakpointRef(frame.code, frame.pc, exc)
    end

    rethrow(exc)
end

function assert_is_toplevel_frame(state)
    state.level == 1 && return true
    printstyled(stderr, "Cannot step or mutate variables in a non toplevel frame,\n"; color=:red)
    return false
end

function execute_command(state::DebuggerState, ::Union{Val{:nc},Val{:n},Val{:se}}, cmd::AbstractString)
    assert_is_toplevel_frame(state) || return false
    pc = try
        cmd == "nc" ? next_call!(state.stack, state.frame) :
        cmd == "n" ? next_line!(state.stack, state.frame) :
        #= cmd == "se" =# step_expr!(state.stack, state.frame)
    catch err
        pc_exc = propagate_exception!(state, err)
        if pc_exc isa JuliaInterpreter.Breakpoints.BreakpointRef
            state.frame = pop!(state.stack)
            show(pc); println()
            return true, false
        end
        next_call!(state.frame, state.frame)
        return true, false
    end
    if pc isa JuliaInterpreter.Breakpoints.BreakpointRef
        state.frame = pop!(state.stack)
        show(pc); println()
    end
    if pc != nothing
        return true, false
    end
    perform_return!(state)
    return true, true
end

function dummy_breakpoint(stack, frame)
    push!(stack, frame)
    return JuliaInterpreter.BreakpointRef(frame.code, 0)
end

function execute_command(state::DebuggerState, md::Union{Val{:s},Val{:si},Val{:sg}}, command::AbstractString)
    assert_is_toplevel_frame(state) || return false, false
    ret = JuliaInterpreter.maybe_next_call!(state.stack, state.frame)
    if ret === nothing
        finish!(state.stack, state.frame)
        return true, false
    elseif isa(ret, JuliaInterpreter.BreakpointRef)
        state.frame = pop!(state.stack)
        return true, false
    else
        pc = ret
        stmt = JuliaInterpreter.pc_expr(state.frame, pc)
        callstmt = stmt
        if isexpr(callstmt, :(=))
            callstmt = callstmt.args[2]
        end
        isexpr(callstmt, :call) || return true, false
        ret = JuliaInterpreter.evaluate_call!(state.stack, state.frame, callstmt, pc; exec! = dummy_breakpoint)
        if isa(ret, JuliaInterpreter.BreakpointRef)
            @show state.frame.exception_frames

            state.frame = pop!(state.stack)
            @show state.frame.exception_frames
            return true, false
        else
            # The call returned in Compiled mode
            JuliaInterpreter.maybe_assign!(stack.frame, stmt, pc, ret)
            state.frame.pc[] += 1
        end
    end
    return true
end

function execute_command(state::DebuggerState, ::Val{:finish}, cmd::AbstractString)
    assert_is_toplevel_frame(state) || return false, false
    pc = finish!(state.stack, state.frame)
    if pc isa JuliaInterpreter.Breakpoints.BreakpointRef
        state.frame = pop!(state.stack)
        show(pc); println()
        return true, false
    end
    perform_return!(state)
    return true, true
end

"""
    Runs code_typed on the call we're about to run
"""
function execute_command(state::DebuggerState, frame::JuliaStackFrame, ::Val{:code_typed}, cmd::AbstractString)
    expr = pc_expr(frame, frame.pc[])
    if isa(expr, Expr)
        if is_call(expr)
            isexpr(expr, :(=)) && (expr = expr.args[2])
            args = map(x->isa(x, QuoteNode) ? x.value : @lookup(frame, x), expr.args)
            f = args[1]
            if f == Core._apply
                f = to_function(args[2])
                args = Base.append_any((args[2],), args[3:end]...)
            end
            if isa(args[1], Core.Builtin)
                return false
            end
            ct = Base.code_typed(f, Base.typesof(args[2:end]...))
            ct = ct == 1 ? ct[1] : ct
            println(ct)
        end
    end
    return false
end


function execute_command(state::DebuggerState, ::Val{:bt}, cmd)
    for (num, frame) in enumerate(Iterators.reverse([state.stack; state.frame]))
        print_frame(Base.pipe_writer(state.terminal), num, frame)
    end
    println()
    return false, false
end

function execute_command(state::DebuggerState, _::JuliaStackFrame, ::Union{Val{:f},Val{:fr}}, cmd)
    subcmds = split(cmd,' ')[2:end]
    if isempty(subcmds) || subcmds[1] == "v"
        @info "Level is $(state.level)"
        print_frame(Base.pipe_writer(state.terminal), state.level, state.stack[end - state.level + 1])
        return false
    else
        new_level = parse(Int, subcmds[1])
        if checkbounds(Bool, state.stack, new_level)
            printstyled(stderr, "Not a valid frame index\n"; color=:red)
            return false
        end
        state.level = new_level
    end
    return true
end

function execute_command(state::DebuggerState, frame, _, cmd)
    println("Unknown command `$cmd`. Executing `?` to obtain help.")
    execute_command(state, frame, Val{Symbol("?")}(), "?")
end

function execute_command(state::DebuggerState, frame::JuliaStackFrame, ::Val{:?}, cmd::AbstractString)
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
