module Debugger

using Markdown
using Base.Meta: isexpr
using REPL
using REPL.LineEdit
using REPL.REPLCompletions

using JuliaInterpreter: JuliaInterpreter, Frame, @lookup, Compiled, FrameCode,
      finish!, enter_call_expr, step_expr!

# TODO: Work on better API in JuliaInterpreter and rewrite Debugger.jl to use it
# These are undocumented functions from JuliaInterpreter.jl used by Debugger.jl`
using JuliaInterpreter: pc_expr,isassign, getlhs, do_assignment!, maybe_next_call!, is_call, next_call!,  moduleof,
                        next_line!, linenumber, extract_args, maybe_step_through_wrapper!


const SEARCH_PATH = []
function __init__()
    append!(SEARCH_PATH,[joinpath(Sys.BINDIR,"../share/julia/base/"),
            joinpath(Sys.BINDIR,"../include/")])
    return nothing
end

export @enter

include("LineNumbers.jl")
using .LineNumbers: SourceFile, compute_line

mutable struct DebuggerState
    frame::Union{Nothing, Frame}
    level::Int
    broke_on_error::Bool
    repl
    terminal
    main_mode
    julia_prompt::Ref{LineEdit.Prompt}
    standard_keymap
    overall_result
end
DebuggerState(stack, repl, terminal) = DebuggerState(stack, 1, false, repl, terminal, nothing, Ref{LineEdit.Prompt}(), nothing, nothing)
DebuggerState(stack, repl) = DebuggerState(stack, repl, nothing)

function active_frame(state)
    frame = state.frame
    for i in 1:(state.level - 1)
        frame = frame.caller
    end
    @assert frame !== nothing
    return frame
end

include("locationinfo.jl")
include("repl.jl")
include("commands.jl")
include("printing.jl")

function _make_stack(mod, arg)
    args = try
        extract_args(mod, arg)
    catch e
        return :(throw($e))
    end
    quote
        theargs = $(esc(args))
        frame = enter_call_expr(Expr(:call,theargs...))
        frame = maybe_step_through_wrapper!(frame)
        maybe_next_call!(frame)
        frame
    end
end

macro make_stack(arg)
    _make_stack(__module__, arg)
end

macro enter(arg)
    quote
        let frame = $(_make_stack(__module__,arg))
            RunDebugger(frame)
        end
    end
end

end # module
