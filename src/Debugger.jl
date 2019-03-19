module Debugger

using Highlights
using Crayons
import InteractiveUtils

using Markdown
using Base.Meta: isexpr
using REPL
using REPL.LineEdit
using REPL.REPLCompletions

using CodeTracking
using JuliaInterpreter: JuliaInterpreter, Frame, @lookup, FrameCode, BreakpointRef, debug_command, leaf, root, BreakpointState

using JuliaInterpreter: pc_expr, moduleof, linenumber, extract_args,
                        root, caller, whereis, get_return, nstatements

const SEARCH_PATH = []
function __init__()
    append!(SEARCH_PATH,[joinpath(Sys.BINDIR,"../share/julia/base/"),
            joinpath(Sys.BINDIR,"../include/")])
    return nothing
end

export @enter, @run, break_on_error

# reexport some useful things from JuliaInterpreter
using JuliaInterpreter: @bp, @breakpoint, breakpoint
export @bp, @breakpoint, breakpoint

include("LineNumbers.jl")
using .LineNumbers: SourceFile, compute_line

# We make WATCH_LIST a global since it is likely useful to keep
# watch expressions between invocations of the debugger interface
const WATCH_LIST = []

mutable struct DebuggerState
    frame::Union{Nothing, Frame}
    level::Int
    broke_on_error::Bool
    watch_list::Vector
    repl
    terminal
    main_mode
    julia_prompt::Ref{LineEdit.Prompt}
    standard_keymap
    overall_result
end
DebuggerState(stack, repl, terminal) = DebuggerState(stack, 1, false, WATCH_LIST, repl, terminal, nothing, Ref{LineEdit.Prompt}(), nothing, nothing)
DebuggerState(stack, repl) = DebuggerState(stack, repl, nothing)

function active_frame(state)
    frame = state.frame
    for i in 1:(state.level - 1)
        frame = caller(frame)
    end
    @assert frame !== nothing
    return frame
end

break_on_error(v::Bool) = JuliaInterpreter.break_on_error[] = v

include("locationinfo.jl")
include("repl.jl")
include("commands.jl")
include("printing.jl")
include("watch.jl")

function _make_frame(mod, arg)
    args = try
        extract_args(mod, arg)
    catch e
        return :(throw($e))
    end
    quote
        theargs = $(esc(args))
        frame = JuliaInterpreter.enter_call_expr(Expr(:call,theargs...))
        frame = JuliaInterpreter.maybe_step_through_wrapper!(frame)
        JuliaInterpreter.maybe_next_call!(frame)
        frame
    end
end

macro make_frame(arg)
    _make_frame(__module__, arg)
end

macro enter(arg)
    quote
        let frame = $(_make_frame(__module__,arg))
            RunDebugger(frame)
        end
    end
end

macro run(arg)
    quote
        let frame = $(_make_frame(__module__,arg))
            RunDebugger(frame; initial_continue=true)
        end
    end
end

end # module
