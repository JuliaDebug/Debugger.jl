dummy_state(stack) = Debugger.DebuggerState(stack, nothing)

# Steps through the whole expression using `s`
function step_through(frame)
    state = dummy_state(frame)
    while state.frame !== nothing
        execute_command(state, Val{:s}(), "s")
    end
    return state.overall_result
end
