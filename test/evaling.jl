using Debugger: eval_code

# Simple evaling of function argument
function evalfoo1(x,y)
    x+y
end
frame = JuliaInterpreter.enter_call_expr(:($(evalfoo1)(1,2)))
res = eval_code(frame, "x")

@test res == 1

res = eval_code(frame, "y")
@test res == 2

# Evaling with sparams
function evalsparams(x::T) where T
    x
end
frame = JuliaInterpreter.enter_call_expr(:($(evalsparams)(1)))
res = eval_code(frame, "x")
@test res == 1
eval_code(frame, "x = 3")
res = eval_code(frame, "x")
@test res == 3
res = eval_code(frame, "T")
@test res == Int
eval_code(frame, "T = Float32")
res = eval_code(frame, "T")
@test res == Float32

# Evaling with keywords
evalkw(x; bar=true) = x
frame = @make_frame evalkw(2)
res = eval_code(frame, "x")
@test res == 2
