function perform_return!(state::DebuggerState)
    returning_frame = state.stack[end]
    returning_expr = pc_expr(returning_frame)
    @assert isexpr(returning_expr, :return)
    val = @lookup(returning_frame, returning_expr.args[1])
    if length(state.stack) != 1
        calling_frame = state.stack[end-1]
        if returning_frame.code.generator
            # Don't do anything here, just return us to where we were
        else
            prev = pc_expr(calling_frame)
            if isexpr(prev, :(=))
                do_assignment!(calling_frame, prev.args[1], val)
            elseif isassign(calling_frame)
                do_assignment!(calling_frame, getlhs(calling_frame.pc[]), val)
            end
            state.stack[end-1] = JuliaStackFrame(calling_frame, maybe_next_call!(Compiled(), calling_frame,
                calling_frame.pc[] + 1))
        end
    else
        @assert !returning_frame.code.generator
        state.overall_result = val
    end
    pop!(state.stack)
    if !isempty(state.stack) && state.stack[end].code.wrapper
        finish!(Compiled(), state.stack[end])
        perform_return!(state)
    end
end

function propagate_exception!(state::DebuggerState, exc)
    while !isempty(state.stack)
        pop!(state.stack)
        isempty(state.stack) && break
        if isa(state.stack[end], JuliaStackFrame)
            if !isempty(state.stack[end].exception_frames)
                # Exception caught
                state.stack[end] = JuliaStackFrame(state.stack[end],
                    JuliaProgramCounter(state.stack[end].exception_frames[end]))
                state.stack[end].last_exception[] = exc
                return true
            end
        end
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
        frame = state.stack[end]
        cmd == "nc" ? next_call!(Compiled(),frame) :
        cmd == "n" ? next_line!(Compiled(), frame, state.stack) :
        #= cmd == "se" =# step_expr!(Compiled(),  frame)
    catch err
        propagate_exception!(state, err)
        next_call!(Compiled(), state.stack[end])
        return true
    end
    if pc != nothing
        return true
    end
    perform_return!(state)
    return true
end

function execute_command(state::DebuggerState, cmd::Union{Val{:s},Val{:si},Val{:sg}}, command::AbstractString)
    assert_is_toplevel_frame(state) || return false
    frame = state.stack[end]
    pc = frame.pc[]
    first = true
    while true
        expr = pc_expr(frame, pc)
        if isa(expr, Expr)
            if is_call(expr)
                isexpr(expr, :(=)) && (expr = expr.args[2])
                args = map(x->isa(x, QuoteNode) ? x.value : @lookup(frame, x), expr.args)
                expr = Expr(:call, args...)
                f = (expr.args[1] == Core._apply) ? expr.args[2] : expr.args[1]
                ok = true
                new_frame = enter_call_expr(expr; enter_generated = command == "sg")
                if new_frame != nothing
                    if (cmd == Val{:s}() || cmd == Val{:sg}())
                        new_frame = JuliaStackFrame(new_frame, maybe_next_call!(Compiled(), new_frame))
                    end
                    # Don't step into Core.Compiler
                    if moduleof(new_frame) == Core.Compiler
                        ok = false
                    else
                        state.stack[end].pc[] = pc
                        push!(state.stack, new_frame)
                        return true
                    end
                else
                    ok = false
                end
                if !ok
                    # It's confusing if we step into the next call, so just go there
                    # and then return
                    state.stack[end] = JuliaStackFrame(frame, next_call!(Compiled(), frame, pc))
                    return true
                end
            elseif !first && isexpr(expr, :return)
                state.stack[end].pc[] = pc
                return true
            end
        end
        first = false
        command == "si" && break
        new_pc = try
            _step_expr!(Compiled(), frame, pc)
        catch err
            propagate_exception!(state, err)
            state.stack[end] = JuliaStackFrame(state.stack[end], next_call!(Compiled(), state.stack[end], pc))
            return true
        end
        if new_pc === nothing
            state.stack[end].pc[] = pc
            perform_return!(state)
            return true
        else
            pc = new_pc
        end
    end
    state.stack[end].pc[] = pc
    return true
end

function execute_command(state::DebuggerState, ::Val{:finish}, cmd::AbstractString)
    assert_is_toplevel_frame(state) || return false
    finish!(Compiled(), state.stack[end])
    perform_return!(state)
    return true
end

"""
    Runs code_typed on the call we're about to run
"""
function execute_command(state::DebuggerState, ::Val{:code_typed}, cmd::AbstractString)
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
    for (num, frame) in enumerate(Iterators.reverse(state.stack))
        print_frame(Base.pipe_writer(state.terminal), num, frame)
    end
    println()
    return false
end

function execute_command(state::DebuggerState, ::Union{Val{:f},Val{:fr}}, cmd)
    subcmds = split(cmd,' ')[2:end]
    if isempty(subcmds) || subcmds[1] == "v"
        @info "Level is $(state.level)"
        print_frame(Base.pipe_writer(state.terminal), state.level, state.stack[end - state.level + 1])
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
