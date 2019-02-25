mutable struct DebuggerState
    stack::Vector{JuliaStackFrame}
    level::Int
    repl
    terminal
    main_mode
    julia_prompt::Ref{LineEdit.Prompt}
    standard_keymap
    overall_result
end
DebuggerState(stack, repl, terminal) = DebuggerState(stack, 1, repl, terminal, nothing, Ref{LineEdit.Prompt}(), nothing, nothing)
DebuggerState(stack, repl) = DebuggerState(stack, repl, nothing)

function sparam_syms(meth::Method)
    s = Symbol[]
    sig = meth.sig
    while sig isa UnionAll
        push!(s, Symbol(sig.var.name))
        sig = sig.body
    end
    return s
end

function print_backtrace(state::DebuggerState)
    for (num, frame) in enumerate(state.stack)
        print_frame(Base.pipe_writer(state.terminal), num, frame)
    end
end

print_backtrace(state::DebuggerState, _::Nothing) = nothing

function execute_command(state::DebuggerState, frame, ::Val{:bt}, cmd)
    print_backtrace(state)
    println()
    return false
end

function execute_command(state::DebuggerState, frame, _, cmd)
    println("Unknown command `$cmd`. Executing `?` to obtain help.")
    execute_command(state, frame, Val{Symbol("?")}(), "?")
end

function execute_command(state::DebuggerState, _::JuliaStackFrame, ::Union{Val{:f},Val{:fr}}, cmd)
    subcmds = split(cmd,' ')[2:end]
    if isempty(subcmds) || subcmds[1] == "v"
        print_frame(Base.pipe_writer(state.terminal), state.level, state.stack[state.level])
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
function debug(meth::Method, args...)
    stack = [enter_call(meth, args...)]
    RunDebugger(stack)
end


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

function loc_for_fname(file::Symbol, line::Integer, defline::Integer)
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
        loc_for_fname(meth.file, linenumber(frame), meth.line)
    else
        println("not yet implemented")
    end
end

function locdesc(frame::JuliaStackFrame)
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
function compute_source_offsets(code::String, offset::Integer, startline::Integer, stopline::Integer; file::SourceFile = SourceFile(code))
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

function print_sourcecode(io::IO, code::String, line::Integer, defline::Integer; file::SourceFile = SourceFile(code))
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

function print_next_state(io::IO, state::DebuggerState, frame::JuliaStackFrame)
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
using Base.IRShow
print_status(io::IO, state::DebuggerState) = print_status(io, state, state.stack[state.level])
function print_status(io::IO, state::DebuggerState, frame::JuliaStackFrame)
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
        print_codeinfo(outbuf, frame)
    end
    print_next_state(outbuf, state, frame)
    print(io, String(take!(outbuf.io)))
end

function print_codeinfo(io::IO, frame::JuliaStackFrame)
    buf = IOBuffer()
    src = frame.code.code
    IRShow.show_ir(IOContext(buf, :SOURCE_SLOTNAMES => Base.sourceinfo_slotnames(src)),
                   src, IRShow.debuginfo[:default](src))
    active_line = convert(Int, frame.pc[])

    code = filter!(x -> !isempty(x), split(String(take!(buf)), '\n'))

    @assert active_line <= length(code)
    for (lineno, line) in enumerate(code)
        (lineno < active_line - 3 || lineno > active_line + 2) && continue

        color = (lineno < active_line) ? :white : :normal
        if lineno == active_line
            printstyled(io, rpad(lineno, 4), bold = true, color = :yellow)
        else
            printstyled(io, rpad(lineno, 4), bold = true, color = color)
        end
        printstyled(io, line, color = color)
        println(io)
    end
    println(io)
end

function eval_code(state::DebuggerState, frame::JuliaStackFrame, command::AbstractString)
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
    function eval_code(state::DebuggerState, code::AbstractString)
        try
            return eval_code(state, state.stack[1], code), false
        catch
            return Base.catch_stack(), true
        end
    end
else
    function eval_code(state::DebuggerState, code::AbstractString)
        try
            return true, eval_code(state, state.stack[1], code)
        catch err
            return false, (err, catch_backtrace())
        end
    end
end
