using DebuggerFramework
using JuliaInterpreter

# Simple evaling of function argument
function evalfoo1(x,y)
    x+y
end
frame = JuliaInterpreter.enter_call_expr(:($(evalfoo1)(1,2)))
res = DebuggerFramework.eval_code(nothing, frame, "x")
@assert res == 1

res = DebuggerFramework.eval_code(nothing, frame, "y")
@assert res == 2

# Evaling with sparams
function evalsparams(x::T) where T
    x
end
frame = JuliaInterpreter.enter_call_expr(:($(evalsparams)(1)))
res = DebuggerFramework.eval_code(nothing, frame, "x")
@assert res == 1

res = DebuggerFramework.eval_code(nothing, frame, "T")
@assert res == Int
