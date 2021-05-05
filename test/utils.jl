dummy_state(frame) = Debugger.DebuggerState(; frame=frame)

# Steps through the whole expression using `s`
function step_through(frame)
    state = dummy_state(frame)
    while state.frame !== nothing
        execute_command(state, Val{:s}(), "s")
    end
    return state.overall_result
end

@test Debugger.repr_limited(Text("ωωω"), 2) == Debugger.suppressed("ω")
