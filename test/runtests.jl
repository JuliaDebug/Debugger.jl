using Debugger: Debugger, @enter, execute_command, RunDebugger, @make_frame
import JuliaInterpreter: JuliaInterpreter, Frame, @lookup, Compiled, pc_expr

using Test
using .Meta: isexpr
import REPL

if !isdefined(Main, :isnothing)
    isnothing(x) = x === nothing
end

#@testset "Main tests" begin
    include("utils.jl")
    include("misc.jl")
    include("stepping.jl")
    include("interpret.jl")
    include("evaling.jl")
    include("ui.jl")
#end
