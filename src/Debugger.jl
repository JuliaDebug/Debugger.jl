module Debugger

using Markdown
using Base.Meta: isexpr
using REPL
using REPL.LineEdit

using JuliaInterpreter: JuliaInterpreter, JuliaStackFrame, @lookup, Compiled, JuliaProgramCounter, JuliaFrameCode,
      finish!, enter_call_expr, step_expr!

# TODO: Work on better API in JuliaInterpreter and rewrite Debugger.jl to use it
# These are undocumented functions from from JuliaInterpreter.jl used by Debugger.jl`
using JuliaInterpreter: _make_stack, pc_expr,isassign, getlhs, do_assignment!, maybe_next_call!, is_call, _step_expr!, next_call!,  moduleof,
                        iswrappercall, next_line!, location


const SEARCH_PATH = []
function __init__()
    append!(SEARCH_PATH,[joinpath(Sys.BINDIR,"../share/julia/base/"),
            joinpath(Sys.BINDIR,"../include/")])
    return nothing
end

export @enter

include("LineNumbers.jl")
using .LineNumbers: SourceFile, compute_line

include("operations.jl")
include("printing.jl")
include("commands.jl")

macro enter(arg)
    quote
        let stack = $(_make_stack(__module__,arg))
            RunDebugger(stack)
        end
    end
end

end # module
