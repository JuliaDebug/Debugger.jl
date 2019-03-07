
function maybe_assign!(frame, stmt, pc, val)
    if isexpr(stmt, :(=))
        lhs = stmt.args[1]
        JuliaInterpreter.do_assignment!(frame, lhs, val)
    elseif JuliaInterpreter.isassign(frame, pc)
        lhs = JuliaInterpreter.getlhs(pc)
        JuliaInterpreter.do_assignment!(frame, lhs, val)
    end
    return nothing
end
maybe_assign!(frame, pc, val) = maybe_assign!(frame, JuliaInterpreter.pc_expr(frame, pc), pc, val)
maybe_assign!(frame, val) = maybe_assign!(frame, JuliaInterpreter.pc_expr(frame, frame.pc[]), frame.pc[], val)

# Returns if this finished the last frame
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
            maybe_assign!(state.frame, val)
            state.frame.pc[] += 1
            maybe_next_call!(state.stack, state.frame)
            return false
        end
    else
        @assert !returning_frame.code.generator
        state.overall_result = val
    end
    if !isempty(state.stack) && state.frame.code.wrapper
        finish!(state.stack, state.frame)
        perform_return!(state)
    end
    return true
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
        # Restore our frame and stack
        state.stack = original_stack
        state.frame = original_frame
        push!(state.stack, state.frame)
        return JuliaInterpreter.BreakpointRef(frame.code, frame.pc, exc)
    end

    rethrow(exc)
end

function assert_allowed_to_step(state::DebuggerState)
    if state.broke_on_error
        printstyled(stderr, "Cannot step after breaking on error\n\n"; color=:red)
        return false
    elseif state.level != 1
        printstyled(stderr, "Cannot step or in a non toplevel frame\n\n"; color=:red)
        return false
    end
    return true
end

function handle_breakpoint!(state::DebuggerState, bp::JuliaInterpreter.BreakpointRef)
    state.broke_on_error = bp.err !== nothing
    state.frame = pop!(state.stack)
    println("Hit breakpoint: $(bp)")
end
    
function execute_command(state::DebuggerState, ::Union{Val{:nc},Val{:n},Val{:se}}, cmd::AbstractString)
    assert_allowed_to_step(state) || return false, false
    pc = try
        cmd == "nc" ? next_call!(state.stack, state.frame) :
        cmd == "n" ? next_line!(state.stack, state.frame) :
        #= cmd == "se" =# step_expr!(state.stack, state.frame)
    catch err
        pc_exc = propagate_exception!(state, err)
        if pc_exc isa JuliaInterpreter.BreakpointRef
            handle_breakpoint!(state, pc_exc)
            return true, false
        end
        next_call!(state.frame, state.frame)
        return true, false
    end
    if pc isa JuliaInterpreter.BreakpointRef
        handle_breakpoint!(state, pc)
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
    assert_allowed_to_step(state) || return false, false
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
        elseif isexpr(callstmt, :return)
            perform_return!(state)
            return true, true
        end
        isexpr(callstmt, :call) || return true, false
        ret = JuliaInterpreter.evaluate_call!(state.stack, state.frame, callstmt, pc; exec! = dummy_breakpoint)
        if isa(ret, JuliaInterpreter.BreakpointRef)
            state.frame = pop!(state.stack)
            JuliaInterpreter.maybe_next_call!(state.stack, state.frame)
            return true, false
        else
            # The call returned in Compiled mode
            maybe_assign!(state.frame, stmt, pc, ret)
            state.frame.pc[] += 1
        end
    end
    return true
end

function execute_command(state::DebuggerState, ::Val{:finish}, cmd::AbstractString)
    finish!(state.stack, state.frame)
    return true, perform_return!(state)
end

"""
    Runs code_typed on the call we're about to run
"""
function execute_command(state::DebuggerState, ::Val{:code_typed}, ::AbstractString)
    frame = active_frame(state)
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
                return false, false
            end
            ct = Base.code_typed(f, Base.typesof(args[2:end]...))
            ct = ct == 1 ? ct[1] : ct
            println(ct)
        end
    end
    return false, false
end


function execute_command(state::DebuggerState, ::Val{:bt}, cmd)
    for (num, frame) in enumerate(Iterators.reverse([state.stack; state.frame]))
        print_frame(Base.pipe_writer(state.terminal), num, frame)
    end
    println()
    return false, false
end

function execute_command(state::DebuggerState, ::Union{Val{:f},Val{:fr}}, cmd)
    subcmds = split(cmd,' ')[2:end]
    if isempty(subcmds) || subcmds[1] == "v"
        frame = active_frame(state)
        print_frame(Base.pipe_writer(state.terminal), state.level, frame)
        return false, false
    else
        new_level = parse(Int, subcmds[1])
        if !checkbounds(Bool, state.stack, new_level)
            printstyled(stderr, "Not a valid frame index\n"; color=:red)
            return false, false
        end
        state.level = new_level
    end
    return true, false
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
    return false, false
end
