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
using JuliaInterpreter: JuliaInterpreter, Frame, @lookup, FrameCode, BreakpointRef, debug_command, leaf, root, BreakpointState, 
                        finish_and_return!, Compiled

using JuliaInterpreter: pc_expr, moduleof, linenumber, extract_args,
                        root, caller, whereis, get_return, nstatements, getargs

const SEARCH_PATH = []
function __init__()
    append!(SEARCH_PATH,[joinpath(Sys.BINDIR,"../share/julia/base/"),
            joinpath(Sys.BINDIR,"../include/")])
    return nothing
end

export @enter, @run

# reexport some useful things from JuliaInterpreter
using JuliaInterpreter: @bp, @breakpoint, breakpoint, break_on, break_off
export @bp, @breakpoint, breakpoint, break_on, break_off, remove, disable

include("LineNumbers.jl")
using .LineNumbers: SourceFile, compute_line

# We make WATCH_LIST a global since it is likely useful to keep
# watch expressions between invocations of the debugger interface
const WATCH_LIST = []

Base.@kwdef mutable struct DebuggerState
    frame::Union{Nothing, Frame}
    level::Int = 1
    broke_on_error::Bool = false
    watch_list::Vector = WATCH_LIST
    lowered_status::Bool = false
    mode = finish_and_return!
    repl = nothing
    terminal = nothing
    main_mode = nothing
    julia_prompt::Ref{LineEdit.Prompt} = Ref{LineEdit.Prompt}()
    standard_keymap = nothing
    overall_result = nothing
end

function toggle_mode(state)
    state.mode = (state.mode === finish_and_return! ? (state.mode = Compiled()) : (state.mode = finish_and_return!))
end

toggle_lowered(state) = state.lowered_status = !state.lowered_status

function active_frame(state)
    frame = state.frame
    for i in 1:(state.level - 1)
        frame = caller(frame)
    end
    @assert frame !== nothing
    return frame
end

@deprecate break_on_error(v::Bool) (v ? break_on(:error) : break_off(:error))

maybe_quote(x) = (isa(x, Expr) || isa(x, Symbol)) ? QuoteNode(x) : x

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
        frame === nothing && error("failed to enter the function, perhaps it is set to run in compiled mode")
        frame = JuliaInterpreter.maybe_step_through_kwprep!(frame)
        frame = JuliaInterpreter.maybe_step_through_wrapper!(frame)
        JuliaInterpreter.maybe_next_call!(frame)
        frame
    end
end

_check_is_call(arg) = !(arg isa Expr && arg.head == :call) && throw(ArgumentError("@enter and @run should be applied to a function call"))

macro make_frame(arg)
    _make_frame(__module__, arg)
end

macro enter(arg)
    _check_is_call(arg)
    quote
        let frame = $(_make_frame(__module__, arg))
            RunDebugger(frame)
        end
    end
end

macro run(arg)
    _check_is_call(arg)
    quote
        let frame = $(_make_frame(__module__, arg))
            RunDebugger(frame; initial_continue=true)
        end
    end
end

end # module
