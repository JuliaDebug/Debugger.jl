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

using JuliaInterpreter: pc_expr, moduleof, linenumber, extract_args, locals,
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
export @bp, @breakpoint, breakpoint, break_on, break_off

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
include("limitio.jl")
include("printing.jl")
include("watches.jl")
include("breakpoints.jl")

function _make_frame(mod, arg)
    args = try
        extract_args(mod, arg)
    catch e
        return :(throw($e))
    end
    quote
        theargs = $(esc(args))
        local frame
        frame = JuliaInterpreter.enter_call_expr(Expr(:call,theargs...))
        frame === nothing && error("failed to enter the function, perhaps it is set to run in compiled mode")
        frame = JuliaInterpreter.maybe_step_through_kwprep!(frame)
        frame = JuliaInterpreter.maybe_step_through_wrapper!(frame)
        JuliaInterpreter.maybe_next_call!(frame)
        frame
    end
end

function _isdotcall(ex::Expr)
    op = ex.args[1]
    return op isa Symbol && Base.isoperator(op) && startswith(string(op), ".")
end

_iscall(ex) = isexpr(ex, :call) && !_isdotcall(ex)

function _preprocess_enter(__source__, ex)
    if _iscall(ex)
        return nothing, ex
    else
        @gensym thunk
        preamble = Expr(:(=), :($thunk()), Expr(:block, __source__, ex))
        arg = :($thunk())
        return esc(preamble), arg
    end
end

macro make_frame(arg)
    _make_frame(__module__, arg)
end

macro enter(ex)
    preamble, arg = _preprocess_enter(__source__, ex)
    quote
        $preamble
        let frame = $(_make_frame(__module__, arg))
            RunDebugger(frame)
        end
    end
end

macro run(ex)
    preamble, arg = _preprocess_enter(__source__, ex)
    quote
        $preamble
        let frame = $(_make_frame(__module__, arg))
            RunDebugger(frame; initial_continue=true)
        end
    end
end

end # module
