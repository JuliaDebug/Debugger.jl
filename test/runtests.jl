using Debugger: Debugger, @enter, execute_command, RunDebugger, @make_stack
import JuliaInterpreter: JuliaInterpreter, JuliaStackFrame, @lookup, Compiled, pc_expr, finish!

using Test
using .Meta: isexpr
import REPL

#@testset "Main tests" begin
    include("utils.jl")
    include("misc.jl")
    include("stepping.jl")
    include("ui.jl")
    include("evaling.jl")
#end
