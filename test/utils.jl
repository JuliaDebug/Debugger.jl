dummy_state(stack) = Debugger.DebuggerState(stack, nothing)

# Steps through the whole expression using `s`
function step_through(frame)
    state = dummy_state([frame])
    while !isexpr(pc_expr(state.stack[1]), :return)
        execute_command(state, Val{:s}(), "s")
    end
    lastframe = state.stack[1]
    return @lookup(lastframe, pc_expr(lastframe).args[1])
end
