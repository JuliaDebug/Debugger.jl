module Debugger

using Highlights
import InteractiveUtils

using Markdown
using Base.Meta: isexpr
using REPL
using REPL.LineEdit
using REPL.REPLCompletions
using REPL.TerminalMenus

using CodeTracking
using JuliaInterpreter: JuliaInterpreter, Frame, lookup, FrameCode, BreakpointRef, debug_command, leaf, root, BreakpointState,
                        finish_and_return!, Interpreter, NonRecursiveInterpreter, RecursiveInterpreter

using JuliaInterpreter: pc_expr, moduleof, linenumber, extract_args, locals,
                        root, caller, whereis, get_return, nstatements, getargs

const SEARCH_PATH = []
function __init__()
    append!(SEARCH_PATH,[joinpath(Sys.BINDIR,"../share/julia/base/"),
            joinpath(Sys.BINDIR,"../include/")])
    init_mixed_mode()
    auto_install_repl_mode()
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

include("mixed_mode.jl")

Base.@kwdef mutable struct DebuggerState
    frame::Union{Nothing, Frame}
    level::Int = 1
    broke_on_error::Bool = false
    watch_list::Vector = WATCH_LIST
    lowered_status::Bool = false
    interp::Interpreter = interp_for_mode(DEFAULT_MODE[])
    # the mode to come back to when the `C` (compiled mode) toggle is switched off
    noncompiled_interp::Interpreter = RecursiveInterpreter()
    repl = nothing
    terminal = nothing
    main_mode = nothing
    julia_prompt::Ref{LineEdit.Prompt} = Ref{LineEdit.Prompt}()
    standard_keymap = nothing
    overall_result = nothing
    # Whether this session switched the terminal to the alternate screen
    # (sticky mode) and is responsible for switching back
    owns_alt_screen::Bool = false
    # Output that must outlive the session's alternate screen (e.g. the error
    # that aborted the session), printed after the main screen is restored
    exit_output::Union{Nothing, String} = nothing
end

function output_stream(state::DebuggerState)
    io = Base.pipe_writer(state.terminal)
    have_color = state.repl isa REPL.LineEditREPL ? state.repl.hascolor : get(io, :color, false)
    return IOContext(io, :color => have_color)
end

# `C` key: binary toggle between compiled mode and the previous non-compiled mode
function toggle_mode(state)
    if state.interp isa NonRecursiveInterpreter
        state.interp = state.noncompiled_interp
    else
        state.noncompiled_interp = state.interp
        state.interp = NonRecursiveInterpreter()
    end
end

# `M` key: binary toggle between mixed and interpreted mode
function toggle_mixed(state)
    if state.interp isa MixedInterpreter
        state.interp = RecursiveInterpreter()
    else
        state.interp = MixedInterpreter()
    end
    state.noncompiled_interp = state.interp
end

function set_session_mode!(state, mode::Symbol)
    new_interp = interp_for_mode(mode)
    if new_interp isa NonRecursiveInterpreter
        # remember the current mode so the `C` toggle returns to it
        if !(state.interp isa NonRecursiveInterpreter)
            state.noncompiled_interp = state.interp
        end
    else
        state.noncompiled_interp = new_interp
    end
    state.interp = new_interp
    return state.interp
end

mode_description(::RecursiveInterpreter) = "interpreted (all code is interpreted, breakpoints always work)"
mode_description(::MixedInterpreter) = "mixed (code outside the focus modules runs natively unless it can reach them)"
mode_description(::NonRecursiveInterpreter) = "compiled (stepped-over code runs natively, breakpoints in it are missed)"

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

include("config.jl")
include("locationinfo.jl")
include("repl.jl")
include("commands.jl")
include("limitio.jl")
include("printing.jl")
include("watches.jl")
include("breakpoints.jl")
include("menus.jl")
include("debugmode.jl")

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
        # Advance to the first call, but stop earlier if a breakpoint is set on
        # one of the initial statements (#134)
        JuliaInterpreter.maybe_next_until!(frame) do fr
            JuliaInterpreter.shouldbreak(fr, fr.pc) ||
                JuliaInterpreter.is_call_or_return(JuliaInterpreter.pc_expr(fr))
        end
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

# Last: the precompile workload uses the macros defined above
include("precompile.jl")

end # module
