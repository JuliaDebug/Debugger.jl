using Debugger: Debugger, @enter, execute_command, RunDebugger, @make_frame
import JuliaInterpreter: JuliaInterpreter, Frame, @lookup, Compiled, pc_expr

using Test
using .Meta: isexpr
import REPL

#@testset "Main tests" begin
    include("utils.jl")
    include("misc.jl")
    include("stepping.jl")
    #include("ui.jl")
    #include("interpret.jl")
    #include("evaling.jl")
#end
