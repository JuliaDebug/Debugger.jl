using Debugger: Debugger, @enter, execute_command, RunDebugger
import JuliaInterpreter: JuliaInterpreter, JuliaStackFrame, @lookup, Compiled, pc_expr, @make_stack, finish!

using Test
using .Meta: isexpr
import REPL

#@testset "Main tests" begin
    include("utils.jl")
    include("misc.jl")
    include("stepping.jl")
    include("ui.jl")
#end
