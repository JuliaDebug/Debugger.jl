# Issue #14

using JuliaInterpreter: JuliaInterpreter, pc_expr, plain, evaluate_call!, finish_and_return!, @lookup, enter_call_expr
# Execute a frame using Julia's regular compiled-code dispatch for any :call expressions
runframe(frame, pc=frame.pc[]) = Some{Any}(finish_and_return!(Compiled(), frame, pc))

stack = @make_stack map(x->2x, 1:10)
state = dummy_state(stack)
execute_command(state, state.stack[1], Val{:finish}(), "finish")
@test isempty(state.stack)
@test state.overall_result == 2 .* [1:10...]

# Issue #12
function complicated_keyword_stuff(args...; kw...)
    args[1] == args[1]
    (args..., kw...)
end
stack = @make_stack complicated_keyword_stuff(1)
state = dummy_state(stack)
execute_command(state, state.stack[1], Val{:n}(), "n")
execute_command(state, state.stack[1], Val{:finish}(), "finish")
@test isempty(state.stack)

@test runframe(JuliaInterpreter.enter_call(complicated_keyword_stuff, 1, 2)) ==
      runframe(@make_stack(complicated_keyword_stuff(1, 2))[1])
@test runframe(JuliaInterpreter.enter_call(complicated_keyword_stuff, 1, 2; x=7, y=33)) ==
      runframe(@make_stack(complicated_keyword_stuff(1, 2; x=7, y=33))[1])

# Issue #22
f22() = string(:(a+b))
@test step_through(enter_call_expr(:($f22()))) == "a + b"
f22() = string(QuoteNode(:a))
@test step_through(enter_call_expr(:($f22()))) == ":a"
