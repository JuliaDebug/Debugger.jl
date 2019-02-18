module Debugger

using Markdown
using Base.Meta: isexpr
using REPL
using REPL.LineEdit

include("DebuggerFramework.jl")
using .DebuggerFramework
using .DebuggerFramework: FileLocInfo, BufferLocInfo, Suppressed

using JuliaInterpreter: JuliaInterpreter, JuliaStackFrame, @lookup, Compiled, JuliaProgramCounter, JuliaFrameCode

# TODO: Work on better API in JuliaInterpreter and rewrite Debugger.jl to use it
using JuliaInterpreter: _make_stack, pc_expr,
finish!, isassign, getlhs, do_assignment!, maybe_next_call!, enter_call_expr, is_call, step_expr!, _step_expr!,
next_call!, iswrappercall, moduleof, next_line!, location

export @enter

const SEARCH_PATH = []
function __init__()
    append!(SEARCH_PATH,[joinpath(Sys.BINDIR,"../share/julia/base/"),
            joinpath(Sys.BINDIR,"../include/")])
    return nothing
end

include("commands.jl")

function DebuggerFramework.locdesc(frame::JuliaStackFrame, specslottypes = false)
    sprint() do io
        if frame.code.scope isa Method
            meth = frame.code.scope
            argnames = frame.code.code.slotnames[2:meth.nargs]
            spectypes = Any[Any for i=1:length(argnames)]
            print(io, meth.name,'(')
            first = true
            for (argname, argT) in zip(argnames, spectypes)
                first || print(io, ", ")
                first = false
                print(io, argname)
                !(argT === Any) && print(io, "::", argT)
            end
            print(io, ") at ",
                frame.code.fullpath ? meth.file :
                basename(String(meth.file)),
                ":",meth.line)
        else
            println("not yet implemented")
        end
    end
end

function DebuggerFramework.print_locals(io::IO, frame::JuliaStackFrame)
    for i = 1:length(frame.locals)
        if !isa(frame.locals[i], Nothing)
            # #self# is only interesting if it has values inside of it. We already know
            # which function we're in otherwise.
            val = something(frame.locals[i])
            if frame.code.code.slotnames[i] == Symbol("#self#") && (isa(val, Type) || sizeof(val) == 0)
                continue
            end
            DebuggerFramework.print_var(io, frame.code.code.slotnames[i], frame.locals[i], nothing)
        end
    end
    if frame.code.scope isa Method
        for i = 1:length(frame.sparams)
            DebuggerFramework.print_var(io, frame.code.scope.sparam_syms[i], frame.sparams[i], nothing)
        end
    end
end

function loc_for_fname(file, line, defline)
    if startswith(string(file),"REPL[")
        hist_idx = parse(Int,string(file)[6:end-1])
        isdefined(Base, :active_repl) || return nothing, ""
        hp = Base.active_repl.interface.modes[1].hist
        return BufferLocInfo(hp.history[hp.start_idx+hist_idx], line, 0, defline)
    else
        for path in SEARCH_PATH
            fullpath = joinpath(path,string(file))
            if isfile(fullpath)
                return FileLocInfo(fullpath, line, 0, defline)
            end
        end
    end
    return nothing
end

function DebuggerFramework.locinfo(frame::JuliaStackFrame)
    if frame.code.scope isa Method
        meth = frame.code.scope
        loc_for_fname(meth.file, location(frame), meth.line)
    else
        println("not yet implemented")
    end
end

function DebuggerFramework.eval_code(state, frame::JuliaStackFrame, command)
    expr = Base.parse_input_line(command)
    if isexpr(expr, :toplevel)
        expr = expr.args[end]
    end
    local_vars = Any[]
    local_vals = Any[]
    for i = 1:length(frame.locals)
        if !isa(frame.locals[i], Nothing)
            push!(local_vars, frame.code.code.slotnames[i])
            push!(local_vals, QuoteNode(something(frame.locals[i])))
        end
    end
    ismeth = frame.code.scope isa Method
    for i = 1:length(frame.sparams)
        ismeth && push!(local_vars, frame.code.scope.sparam_syms[i])
        push!(local_vals, QuoteNode(frame.sparams[i]))
    end
    res = gensym()
    eval_expr = Expr(:let,
        Expr(:block, map(x->Expr(:(=), x...), zip(local_vars, local_vals))...),
        Expr(:block,
            Expr(:(=), res, expr),
            Expr(:tuple, res, Expr(:tuple, local_vars...))
        ))
    eval_res, res = Core.eval(moduleof(frame), eval_expr)
    j = 1
    for i = 1:length(frame.locals)
        if !isa(frame.locals[i], Nothing)
            frame.locals[i] = Some{Any}(res[j])
            j += 1
        end
    end
    for i = 1:length(frame.sparams)
        frame.sparams[i] = res[j]
        j += 1
    end
    eval_res
end

function maybe_quote(x)
    (isa(x, Expr) || isa(x, Symbol)) ? QuoteNode(x) : x
end

function DebuggerFramework.print_next_state(io::IO, state, frame::JuliaStackFrame)
    print(io, "About to run: ")
    expr = pc_expr(frame, frame.pc[])
    isa(expr, Expr) && (expr = copy(expr))
    if isexpr(expr, :(=))
        expr = expr.args[2]
    end
    if isexpr(expr, :call) || isexpr(expr, :return)
        expr.args = map(var->maybe_quote(@lookup(frame, var)), expr.args)
    end
    if isa(expr, Expr)
        for (i, arg) in enumerate(expr.args)
            try
                nbytes = length(repr(arg))
                if nbytes > max(40, div(200, length(expr.args)))
                    expr.args[i] = Suppressed("$nbytes bytes of output")
                end
            catch
                expr.args[i] = Suppressed("printing error")
            end
        end
    end
    print(io, expr)
    println(io)
end

const all_commands = ("q", "s", "si", "finish", "bt", "loc", "ind",
    "up", "down", "nc", "n", "se")

function DebuggerFramework.language_specific_prompt(state, frame::JuliaStackFrame)
    if haskey(state.language_modes, :julia)
        return state.language_modes[:julia]
    end
    julia_prompt = LineEdit.Prompt(DebuggerFramework.promptname(state.level, "julia");
        # Copy colors from the prompt object
        prompt_prefix = state.repl.prompt_color,
        prompt_suffix = (state.repl.envcolors ? Base.input_color : state.repl.input_color),
        complete = REPL.REPLCompletionProvider(),
        on_enter = REPL.return_callback)
    julia_prompt.hist = state.main_mode.hist
    julia_prompt.hist.mode_mapping[:julia] = julia_prompt

    julia_prompt.on_done = (s,buf,ok)->begin
        if !ok
            LineEdit.transition(s, :abort)
            return false
        end
        xbuf = copy(buf)
        command = String(take!(buf))
        @static if VERSION >= v"1.2.0-DEV.253"
            response = DebuggerFramework.eval_code(state, command)
            REPL.print_response(state.repl, response, true, true)
        else
            ok, result = DebuggerFramework.eval_code(state, command)
            REPL.print_response(state.repl, ok ? result : result[1], ok ? nothing : result[2], true, true)
        end
        println(state.repl.t)

        if !ok
            # Convenience hack. We'll see if this is more useful or annoying
            for c in all_commands
                !startswith(command, c) && continue
                LineEdit.transition(s, state.main_mode)
                LineEdit.state(s, state.main_mode).input_buffer = xbuf
                break
            end
        end
        LineEdit.reset_state(s)
    end
    julia_prompt.keymap_dict = LineEdit.keymap([REPL.mode_keymap(state.main_mode);state.standard_keymap])
    state.language_modes[:julia] = julia_prompt
    return julia_prompt
end

function DebuggerFramework.debug(meth::Method, args...)
    stack = [enter_call(meth, args...)]
    DebuggerFramework.RunDebugger(stack)
end

macro enter(arg)
    quote
        let stack = $(_make_stack(__module__,arg))
            DebuggerFramework.RunDebugger(stack)
        end
    end
end
end # module
