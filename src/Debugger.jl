module Debugger

using Markdown
using Base.Meta: isexpr
using REPL
using REPL.LineEdit
using REPL.REPLCompletions

using JuliaInterpreter: JuliaInterpreter, JuliaStackFrame, @lookup, Compiled, JuliaProgramCounter, JuliaFrameCode,
      finish!, enter_call_expr, step_expr!

# TODO: Work on better API in JuliaInterpreter and rewrite Debugger.jl to use it
# These are undocumented functions from JuliaInterpreter.jl used by Debugger.jl`
using JuliaInterpreter: pc_expr,isassign, getlhs, do_assignment!, maybe_next_call!, is_call, _step_expr!, next_call!,  moduleof,
                        iswrappercall, next_line!, linenumber, extract_args


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
    stack::Vector{JuliaStackFrame}
    frame::JuliaStackFrame
    level::Int
    broke_on_error::Bool
    repl
    terminal
    main_mode
    julia_prompt::Ref{LineEdit.Prompt}
    standard_keymap
    overall_result
end
DebuggerState(stack, frame, repl, terminal) = DebuggerState(stack, frame, 1, false, repl, terminal, nothing, Ref{LineEdit.Prompt}(), nothing, nothing)
DebuggerState(stack, frame, repl) = DebuggerState(stack, frame, repl, nothing)

active_frame(state::DebuggerState) = state.level == 1 ? state.frame : state.stack[end - state.level + 2]

"""
    Start debugging the specified code in the the specified environment.
    The second argument should default to the global environment if such
    an environment exists for the language in question.
"""
function debug(meth::Method, args...)
    RunDebugger(JuliaStackFrame[], enter_call(meth, args...))
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
        stack = [enter_call_expr(Expr(:call,theargs...))]
        maybe_step_through_wrapper!(stack)
        stack[end] = JuliaStackFrame(stack[end], JuliaInterpreter.maybe_next_call!(Compiled(), stack[end]))
        stack, pop!(stack)
    end
end

function maybe_step_through_wrapper!(stack)
    length(stack[end].code.code.code) < 2 && return stack
    last = stack[end].code.code.code[end-1]
    isexpr(last, :(=)) && (last = last.args[2])
    stack1 = stack[end]
    is_kw = stack1.code.scope isa Method && startswith(String(Base.unwrap_unionall(Base.unwrap_unionall(stack1.code.scope.sig).parameters[1]).name.name), "#kw")
    if is_kw || isexpr(last, :call) && any(x->x==Core.SlotNumber(1), last.args)
        # If the last expr calls #self# or passes it to an implementation method,
        # this is a wrapper function that we might want to step through
        frame = stack1
        pc = frame.pc[]
        while pc != JuliaProgramCounter(length(frame.code.code.code)-1)
            pc = next_call!(Compiled(), frame, pc)
        end
        stack[end] = JuliaStackFrame(JuliaFrameCode(frame.code; wrapper=true), frame, pc)
        newcall = Expr(:call, map(x->@lookup(frame, x), last.args)...)
        push!(stack, enter_call_expr(newcall))
        return maybe_step_through_wrapper!(stack)
    end
    return stack
end

macro make_stack(arg)
    _make_stack(__module__, arg)
end

macro enter(arg)
    quote
        let stackdata = $(_make_stack(__module__,arg))
            stack, frame = stackdata
            RunDebugger(stack, frame)
        end
    end
end

end # module
