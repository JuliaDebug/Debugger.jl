module DebuggerFramework

include("LineNumbers.jl")

using .Meta: isexpr

using .LineNumbers: SourceFile, compute_line

import ..Debugger: JuliaStackFrame, location, moduleof, @lookup, pc_expr

struct Suppressed{T}
    item::T
end
Base.show(io::IO, x::Suppressed) = print(io, "<suppressed ", x.item, '>')

function print_var(io::IO, name, val, undef_callback)
    print("  | ")
    if val === nothing
        @assert false
    else
        val = something(val)
        T = typeof(val)
        try
            val = repr(val)
            if length(val) > 150
                val = Suppressed("$(length(val)) bytes of output")
            end
        catch
            val = Suppressed("printing error")
        end
        println(io, name, "::", T, " = ", val)
    end
end


function sparam_syms(meth::Method)
    s = Symbol[]
    sig = meth.sig
    while sig isa UnionAll
        push!(s, Symbol(sig.var.name))
        sig = sig.body
    end
    return s
end

function print_locals(io::IO, frame::JuliaStackFrame)
    for i = 1:length(frame.locals)
        if !isa(frame.locals[i], Nothing)
            # #self# is only interesting if it has values inside of it. We already know
            # which function we're in otherwise.
            val = something(frame.locals[i])
            if frame.code.code.slotnames[i] == Symbol("#self#") && (isa(val, Type) || sizeof(val) == 0)
                continue
            end
            print_var(io, frame.code.code.slotnames[i], frame.locals[i], nothing)
        end
    end
    if frame.code.scope isa Method
        for (sym, value) in zip(sparam_syms(frame.code.scope), frame.sparams)
            print_var(io, sym, value, nothing)
        end
    end
end

print_locdesc(io, frame) = println(io, locdesc(frame))
function print_frame(_, io::IO, num, frame)
    print(io, "[$num] ")
    print_locdesc(io, frame)
    print_locals(io, frame)
end

function print_backtrace(state)
    for (num, frame) in enumerate(state.stack)
        print_frame(state, Base.pipe_writer(state.terminal), num, frame)
    end
end

print_backtrace(state, _::Nothing) = nothing

function execute_command(state, frame, ::Val{:bt}, cmd)
    print_backtrace(state)
    println()
    return false
end

function execute_command(state, frame, _, cmd)
    println("Unknown command `$cmd`. Executing `?` to obtain help.")
    execute_command(state, frame, Val{Symbol("?")}(), "?")
end

function execute_command(state, interp, ::Union{Val{:f},Val{:fr}}, command)
    subcmds = split(command,' ')[2:end]
    if isempty(subcmds) || subcmds[1] == "v"
        print_frame(state, Base.pipe_writer(state.terminal), state.level, state.stack[state.level])
        return false
    else
        new_level = parse(Int, subcmds[1])
        new_stack_idx = length(state.stack)-(new_level-1)
        if new_stack_idx > length(state.stack) || new_stack_idx < 1
            printstyled(stderr, "Not a valid frame index\n"; color=:red)
            return false
        end
        state.level = new_level
    end
    return true
end

"""
    Start debugging the specified code in the the specified environment.
    The second argument should default to the global environment if such
    an environment exists for the language in question.
"""
function debug
end

mutable struct DebuggerState
    stack
    level
    repl
    main_mode
    language_modes
    standard_keymap
    terminal
    overall_result
end
dummy_state(stack) = DebuggerState(stack, 1, nothing, nothing, nothing, nothing, nothing, nothing)

struct FileLocInfo
    filepath::String
    line::Int
    # 0 if unknown
    column::Int
    # The line at which the current context starts, 0 if unknown
    defline::Int
end

struct BufferLocInfo
    data::String
    line::Int
    # 0 if unknown
    column::Int
    defline::Int
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

function locinfo(frame::JuliaStackFrame)
    if frame.code.scope isa Method
        meth = frame.code.scope
        loc_for_fname(meth.file, location(frame), meth.line)
    else
        println("not yet implemented")
    end
end

function locdesc(frame::JuliaStackFrame, specslottypes = false)
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

"""
Determine the offsets in the source code to print, based on the offset of the
currently highlighted part of the code, and the start and stop line of the
entire function.
"""
function compute_source_offsets(code, offset, startline, stopline; file = SourceFile(code))
    offsetline = compute_line(file, offset)
    if offsetline - 3 > length(file.offsets) || startline > length(file.offsets)
        return -1, -1
    end
    startoffset = max(file.offsets[max(offsetline-3,1)], file.offsets[startline])
    stopoffset = lastindex(code)-1
    if offsetline + 3 < lastindex(file.offsets)
        stopoffset = min(stopoffset, file.offsets[offsetline + 3]-1)
    end
    if stopline + 1 < lastindex(file.offsets)
        stopoffset = min(stopoffset, file.offsets[stopline + 1]-1)
    end
    startoffset, stopoffset
end

function print_sourcecode(io, code, line, defline; file = SourceFile(code))
    startoffset, stopoffset = compute_source_offsets(code, file.offsets[line], defline, line+3; file=file)

    if startoffset == -1
        printstyled(io, "Line out of file range (bad debug info?)", color=:bold)
        return
    end

    # Compute necessary data for line numbering
    startline = compute_line(file, startoffset)
    stopline = compute_line(file, stopoffset)
    current_line = line
    stoplinelength = length(string(stopline))

    code = split(code[(startoffset+1):(stopoffset+1)],'\n')
    lineno = startline

    if !isempty(code) && isempty(code[end])
        pop!(code)
    end

    for textline in code
        printstyled(io,
            string(lineno, " "^(stoplinelength-length(lineno)+1));
            color = lineno == current_line ? :yellow : :bold)
        println(io, textline)
        lineno += 1
    end
    println(io)
end

function maybe_quote(x)
    (isa(x, Expr) || isa(x, Symbol)) ? QuoteNode(x) : x
end

function print_next_state(io::IO, state, frame::JuliaStackFrame)
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

print_status(io, state) = print_status(io, state, state.stack[state.level])
function print_status(io, state, frame)
    # Buffer to avoid flickering
    outbuf = IOContext(IOBuffer(), io)
    printstyled(outbuf, "In ", locdesc(frame), "\n"; color=:bold)
    loc = locinfo(frame)
    if loc !== nothing
        data = if isa(loc, BufferLocInfo)
                loc.data
            else
                VERSION < v"0.7" ? read(loc.filepath, String) :
                read(loc.filepath, String)
            end
        print_sourcecode(outbuf, data,
            loc.line, loc.defline)
    else
        buf = IOBuffer()
        # TODO: look at the = 0
        active_line = 0
        code = split(String(take!(buf)),'\n')
        @assert active_line <= length(code)
        for (lineno, line) in enumerate(code)
            if lineno == active_line
                printstyled(outbuf, "=> ", bold = true, color=:yellow); println(outbuf, line)
            else
                printstyled(outbuf, "?  ", bold = true); println(outbuf, line)
            end
        end
    end
    print_next_state(outbuf, state, frame)
    print(io, String(take!(outbuf.io)))
end

abstract type AbstractDiagnostic; end

function execute_command
end


const all_commands = ("q", "s", "si", "finish", "bt", "nc", "n", "se")

function julia_prompt(state, frame::JuliaStackFrame)
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
            val, iserr = response
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

function eval_code(state, frame::JuliaStackFrame, command)
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
    ismeth && (syms = sparam_syms(frame.code.scope))
    for i = 1:length(frame.sparams)
        ismeth && push!(local_vars, syms[i])
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

@static if VERSION >= v"1.2.0-DEV.253"
    function eval_code(state, code)
        try
            result = eval_code(state, state.stack[1], code)
            result, false
        catch err
            response = Base.catch_stack()
            response, true
        end
    end
else
    function eval_code(state, code)
        try
            result = eval_code(state, state.stack[1], code)
            true, result
        catch err
            bt = catch_backtrace()
            false, (err, bt)
        end
    end
end

using REPL
using REPL.LineEdit
promptname(level, name) = "$level|$name > "
function RunDebugger(stack, repl = Base.active_repl, terminal = Base.active_repl.t)

    state = DebuggerState(stack, 1, repl, nothing, Dict{Symbol, Any}(), nothing, terminal, nothing)

    # Setup debug panel
    panel = LineEdit.Prompt(promptname(state.level, "debug");
        prompt_prefix="\e[38;5;166m",
        prompt_suffix=Base.text_colors[:white],
        on_enter = s->true)

    panel.hist = REPL.REPLHistoryProvider(Dict{Symbol,Any}(:debug => panel))
    REPL.history_reset_state(panel.hist)

    search_prompt, skeymap = LineEdit.setup_search_keymap(panel.hist)
    search_prompt.complete = REPL.LatexCompletions()

    state.main_mode = panel

    panel.on_done = (s,buf,ok)->begin
        line = String(take!(buf))
        old_level = state.level
        if !ok || strip(line) == "q"
            LineEdit.transition(s, :abort)
            LineEdit.reset_state(s)
            return false
        end
        if isempty(strip(line)) && length(panel.hist.history) > 0
            command = panel.hist.history[end]
        else
            command = strip(line)
        end
        do_print_status = true
        cmd1 = split(command,' ')[1]
        do_print_status = try
            execute_command(state, state.stack[state.level], Val{Symbol(cmd1)}(), command)
        catch err
            rethrow(err)
        end
        if old_level != state.level
            panel.prompt = promptname(state.level,"debug")
        end
        LineEdit.reset_state(s)
        if isempty(state.stack)
            LineEdit.transition(s, :abort)
            LineEdit.reset_state(s)
            return false
        end
        if do_print_status
            print_status(Base.pipe_writer(terminal), state)
        end
        return true
    end

    key = '`'
    repl_switch = Dict{Any,Any}(
        key => function (s,args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                prompt = julia_prompt(state, state.stack[1])
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, prompt) do
                    LineEdit.state(s, prompt).input_buffer = buf
                end
            else
                LineEdit.edit_insert(s,key)
            end
        end
    )

    state.standard_keymap = Dict{Any,Any}[skeymap, LineEdit.history_keymap, LineEdit.default_keymap, LineEdit.escape_defaults]
    panel.keymap_dict = LineEdit.keymap([repl_switch;state.standard_keymap])

    print_status(Base.pipe_writer(terminal), state)
    REPL.run_interface(terminal, LineEdit.ModalInterface([panel,search_prompt]))

    state.overall_result
end

end # module
