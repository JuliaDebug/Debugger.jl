using Debugger
import Debugger: DebuggerFramework
import JuliaInterpreter: JuliaStackFrame, @lookup, _make_stack, Compiled, pc_expr, @make_stack, finish!, isexpr

import .DebuggerFramework: dummy_state, execute_command

using Test

#@testset "Main tests" begin
    include("utils.jl")
    include("misc.jl")
    include("stepping.jl")
    include("ui.jl")
#end
