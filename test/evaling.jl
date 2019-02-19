using JuliaInterpreter

# Simple evaling of function argument
function evalfoo1(x,y)
    x+y
end
frame = JuliaInterpreter.enter_call_expr(:($(evalfoo1)(1,2)))
res = eval_code(nothing, frame, "x")
@test res == 1

res = eval_code(nothing, frame, "y")
@test res == 2

# Evaling with sparams
function evalsparams(x::T) where T
    x
end
frame = JuliaInterpreter.enter_call_expr(:($(evalsparams)(1)))
res = eval_code(nothing, frame, "x")
@test res == 1

res = eval_code(nothing, frame, "T")
@test res == Int
