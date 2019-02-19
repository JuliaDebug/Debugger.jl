using Debugger: Debugger, @enter, execute_command, RunDebugger
import JuliaInterpreter: JuliaStackFrame, @lookup, _make_stack, Compiled, pc_expr, @make_stack, finish!, isexpr

using Test

#@testset "Main tests" begin
    include("utils.jl")
    include("misc.jl")
    include("stepping.jl")
    include("ui.jl")
#end
