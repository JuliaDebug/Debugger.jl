dummy_state(stack, frame) = Debugger.DebuggerState(stack, frame, nothing)

# Steps through the whole expression using `s`
function step_through(frame)
    state = dummy_state(JuliaStackFrame[], frame)
    while !isexpr(pc_expr(state.frame), :return)
        JuliaInterpreter.locals(frame)
        execute_command(state, Val{:s}(), "s")
    end
    pc_expr(state.frame)
    return @lookup(state.frame, pc_expr(state.frame).args[1])
end
