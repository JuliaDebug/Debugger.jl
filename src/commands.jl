function perform_return!(state)
    returning_frame = state.stack[1]
    returning_expr = pc_expr(returning_frame)
    @assert isexpr(returning_expr, :return)
    val = @lookup(returning_frame, returning_expr.args[1])
    if length(state.stack) != 1
        calling_frame = state.stack[2]
        if returning_frame.code.generator
            # Don't do anything here, just return us to where we were
        else
            prev = plain(pc_expr(calling_frame))
            if isexpr(prev, :(=))
                do_assignment!(calling_frame, prev.args[1], val)
            elseif isassign(calling_frame)
                do_assignment!(calling_frame, getlhs(calling_frame.pc[]), val)
            end
            state.stack[2] = JuliaStackFrame(calling_frame, maybe_next_call!(Compiled(), calling_frame,
                calling_frame.pc[] + 1))
        end
    else
        @assert !returning_frame.code.generator
        state.overall_result = val
    end
    popfirst!(state.stack)
    if !isempty(state.stack) && state.stack[1].code.wrapper
        state.stack[1] = JuliaStackFrame(state.stack[1], finish!(Compiled(), state.stack[1]))
        perform_return!(state)
    end
end

function propagate_exception!(state, exc)
    while !isempty(state.stack)
        popfirst!(state.stack)
        isempty(state.stack) && break
        if isa(state.stack[1], JuliaStackFrame)
            if !isempty(state.stack[1].exception_frames)
                # Exception caught
                state.stack[1] = JuliaStackFrame(state.stack[1],
                    JuliaProgramCounter(state.stack[1].exception_frames[end]))
                state.stack[1].last_exception[] = exc
                return true
            end
        end
    end
    rethrow(exc)
end

function DebuggerFramework.execute_command(state, frame::JuliaStackFrame, ::Union{Val{:nc},Val{:n},Val{:se}}, command)
    pc = try
        command == "nc" ? next_call!(Compiled(), frame) :
        command == "n" ? next_line!(Compiled(), frame, state.stack) :
        #= command == "se" =# step_expr!(Compiled(), frame)
    catch err
        propagate_exception!(state, err)
        state.stack[1] = JuliaStackFrame(state.stack[1], next_call!(Compiled(), state.stack[1], state.stack[1].pc[]))
        return true
    end
    if pc != nothing
        state.stack[1] = JuliaStackFrame(state.stack[1], pc)
        return true
    end
    perform_return!(state)
    return true
end

function DebuggerFramework.execute_command(state, frame::JuliaStackFrame, cmd::Union{Val{:s},Val{:si},Val{:sg}}, command)
    pc = frame.pc[]
    first = true
    while true
        expr = plain(pc_expr(frame, pc))
        if isa(expr, Expr)
            if is_call(expr)
                isexpr(expr, :(=)) && (expr = expr.args[2])
                args = map(x->isa(x, QuoteNode) ? x.value : @lookup(frame, x), expr.args)
                expr = Expr(:call, args...)
                f = (expr.args[1] == Core._apply) ? expr.args[2] : expr.args[1]
                ok = true
                if !isa(f, Union{Core.Builtin, Core.IntrinsicFunction})
                    new_frame = enter_call_expr(expr;
                        enter_generated = command == "sg")
                    if (cmd == Val{:s}() || cmd == Val{:sg}())
                        new_frame = JuliaStackFrame(new_frame, maybe_next_call!(Compiled(), new_frame))
                    end
                    # Don't step into Core.Compiler
                    if moduleof(new_frame) == Core.Compiler
                        ok = false
                    else
                        state.stack[1] = JuliaStackFrame(frame, pc)
                        pushfirst!(state.stack, new_frame)
                        return true
                    end
                else
                    ok = false
                end
                if !ok
                    # It's confusing if we step into the next call, so just go there
                    # and then return
                    state.stack[1] = JuliaStackFrame(frame, next_call!(Compiled(), frame, pc))
                    return true
                end
            elseif !first && isexpr(expr, :return)
                state.stack[1] = JuliaStackFrame(frame, pc)
                return true
            end
        end
        first = false
        command == "si" && break
        new_pc = try
            _step_expr!(Compiled(), frame, pc)
        catch err
            propagate_exception!(state, err)
            state.stack[1] = JuliaStackFrame(state.stack[1], next_call!(Compiled(), state.stack[1], pc))
            return true
        end
        if new_pc == nothing
            state.stack[1] = JuliaStackFrame(frame, pc)
            perform_return!(state)
            return true
        else
            pc = new_pc
        end
    end
    state.stack[1] = JuliaStackFrame(frame, pc)
    return true
end

function DebuggerFramework.execute_command(state, frame::JuliaStackFrame, ::Val{:finish}, cmd)
    state.stack[1] = JuliaStackFrame(frame, finish!(Compiled(), frame))
    perform_return!(state)
    return true
end

"""
    Runs code_typed on the call we're about to run
"""
function DebuggerFramework.execute_command(state, frame::JuliaStackFrame, ::Val{:code_typed}, cmd)
    expr = plain(pc_expr(frame, frame.pc[]))
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


function DebuggerFramework.execute_command(state, frane::JuliaStackFrame, ::Val{:?}, cmd)
    display(
            @md_str """
    Basic Commands:\\
    - `n` steps to the next line\\
    - `s` steps into the next call\\
    - `finish` runs to the end of the function\\
    - `bt` shows a simple backtrace\\
    - ``` `stuff ``` runs `stuff` in the current frame's context\\
    - `fr v` will show all variables in the current frame\\
    - `f n` where `n` is an integer, will go to the `n`-th frame.\\
    Advanced commands:\\
    - `nc` steps to the next call\\
    - `se` does one expression step\\
    - `si` does the same but steps into a call if a call is the next expression\\
    - `sg` steps into a generated function\\
    """)
    return false
end
