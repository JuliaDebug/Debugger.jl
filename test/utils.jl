# Steps through the whole expression using `s`
function step_through(frame)
    state = DebuggerFramework.dummy_state([frame])
    while !isexpr(pc_expr(state.stack[end]), :return)
        execute_command(state, state.stack[1], Val{:s}(), "s")
    end
    lastframe = state.stack[end]
    return @lookup(lastframe, pc_expr(lastframe).args[1])
end
