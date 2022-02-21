const MAX_BYTES_REPR = Ref(100)
suppressed(str) = string("<", str, "...>")

function repr_limited(val, n, f=show)
    iob = IOBuffer()
    local limited_str
    try
        limit_io = LimitIO(iob, n)
        f(limit_io, val)
        limited_str = String(take!(iob))
    catch e
        if e isa LimitIOException
            limited_str = String(take!(iob))
            limited_str = suppressed(limited_str)
        else
            limited_str = suppressed("printing error")
        end
    end
    return filter(isvalid, limited_str)
end

function print_var(io::IO, var::JuliaInterpreter.Variable)
    print(io, "  | ")
    T = typeof(var.value)
    val = repr_limited(var.value, MAX_BYTES_REPR[])
    println(io, highlight_code(string(var.name, "::", T, " = ", val); context=io))
end

function print_locals(io::IO, frame::Frame)
    vars = JuliaInterpreter.locals(frame)
    for var in vars
        # Hide gensymmed variables
        startswith(string(var.name), "#") && continue
        print_var(io, var)
    end
end

function print_frame(io::IO, num::Integer, frame::Frame; current_line=false)
    print(io, "[$num] ")
    println(io, locdesc(frame; current_line=current_line))
    print_locals(io, frame)
end

function pattern_match_kw_call(expr)
    if isexpr(expr, :call)
        f = string(expr.args[1])
        is_kw = occursin("#kw#", f) || (startswith(f, "#") && endswith(f, "_kw"))
    else
        is_kw = false
    end
    is_kw || return expr
    args = length(expr.args) >= 4 ? expr.args[4:end] : []
    kws_nt = expr.args[2]
    kws = []
    for (k, w) in pairs(kws_nt)
        push!(kws, Expr(:kw, k, w))
    end
    f = expr.args[3]
    return :($f($(args...); $(kws...)))
end

@static if VERSION < v"1.3.0-DEV.179"
    const append_any = Base.append_any
else
    append_any(@nospecialize x...) = append!([], Core.svec((x...)...))
end

function pattern_match_apply_call(expr, frame)
    if !(isexpr(expr, :call) && expr.args[1] == Core._apply)
        return expr
    end
    args = [@lookup(frame, expr.args[i+2]) for i in 1:(length(expr.args)-2)]
    new_expr = Expr(:call, expr.args[2])
    argsflat = append_any(args...)
    for x in argsflat
        push!(new_expr.args, (isa(x, Symbol) || isa(x, Expr) || isa(x, QuoteNode)) ? QuoteNode(x) : x)
    end
    return new_expr
end

function print_next_expr(io::IO, frame::Frame)
    expr = pc_expr(frame)
    @assert expr !== nothing
    print(io, "About to run: ")
    isa(expr, Expr) && (expr = copy(expr))
    if isexpr(expr, :(=))
        expr = expr.args[2]
    end
    if isexpr(expr, :call) || isexpr(expr, :return)
        for i in 1:length(expr.args)
            val = try
                @lookup(frame, expr.args[i])
            catch err
                err isa UndefVarError || rethrow(err)
                expr.args[i]
            end
            expr.args[i] = maybe_quote(val)
        end
    end
    if isdefined(Core, :ReturnNode)
        if expr isa Core.ReturnNode
            val = try
                @lookup(frame, expr.val)
            catch err
                err isa UndefVarError || rethrow(err)
                expr.val
            end
            expr = Expr(:return, maybe_quote(val))
        end
    end
    expr = pattern_match_kw_call(expr)
    expr = pattern_match_apply_call(expr, frame)
    limit_expr = repr_limited(expr, MAX_BYTES_REPR[], print)
    print(io, highlight_code(limit_expr; context=io))
    println(io)
end

function breakpoint_linenumbers(frame::Frame; lowered=false)
    framecode = frame.framecode
    breakpoint_lines = Dict{Int, BreakpointState}()
    for stmtidx in 1:length(framecode.breakpoints)
        isassigned(framecode.breakpoints, stmtidx) || continue
        bp = framecode.breakpoints[stmtidx]
        line = lowered ? stmtidx : JuliaInterpreter.linenumber(frame, stmtidx)
        breakpoint_lines[line] = bp
    end
    return breakpoint_lines
end

function print_status(io::IO, frame::Frame; force_lowered=false)
    # Buffer to avoid flickering
    outbuf = IOContext(IOBuffer(), io)
    printstyled(outbuf, "In ", locdesc(frame), "\n")
    loc = locinfo(frame)

    if loc !== nothing && !force_lowered
        defline, deffile, current_line, body = loc
        breakpoint_lines = breakpoint_linenumbers(frame)
        ok = print_sourcecode(outbuf, body, current_line, defline, deffile, breakpoint_lines)
        if !ok
            printstyled(io, "failed to lookup source code, showing lowered code:\n"; color=Base.warn_color())
            print_codeinfo(outbuf, frame)
        end
    else
        print_codeinfo(outbuf, frame)
    end
    print_next_expr(outbuf, frame)
    print(io, String(take!(outbuf.io)))
end

const NUM_SOURCE_LINES_UP_DOWN = Ref(4)

function print_codeinfo(io::IO, frame::Frame)
    src = frame.framecode.src
    if isdefined(JuliaInterpreter, Symbol("replace_coretypes!"))
        src = copy(src)
        JuliaInterpreter.replace_coretypes!(src; rev=true)
    end
    code = JuliaInterpreter.framecode_lines(src)
    active_line = convert(Int, frame.pc[])
    startline = max(1, active_line - NUM_SOURCE_LINES_UP_DOWN[])
    endline = min(length(code), active_line + NUM_SOURCE_LINES_UP_DOWN[])
    code = code[startline:endline]
    breakpoint_lines = breakpoint_linenumbers(frame; lowered=true)
    print_lines(io, code, active_line, breakpoint_lines, startline)
end

"""
Determine the offsets in the source code to print, based on the offset of the
currently highlighted part of the code, and the start and stop line of the
entire function.
"""
function compute_source_offsets(code::AbstractString, current_offsetline::Integer, file::SourceFile)
    desired_startline = current_offsetline - NUM_SOURCE_LINES_UP_DOWN[]
    desired_stopline = current_offsetline + NUM_SOURCE_LINES_UP_DOWN[] + 1
    if desired_startline > length(file.offsets)
        return -1, -1
    end
    desired_startline = max(desired_startline, 1)
    startoffset = file.offsets[desired_startline]
    stopoffset = lastindex(code)-1
    if desired_stopline < lastindex(file.offsets)
        stopoffset = file.offsets[desired_stopline]
    end
    startoffset, stopoffset
end

@enum HighlightOption begin
    HIGHLIGHT_OFF
    HIGHLIGHT_SYSTEM_COLORS
    HIGHLIGHT_256_COLORS
    HIGHLIGHT_24_BIT
end

const _syntax_highlighting = Ref(Sys.iswindows() ? HIGHLIGHT_SYSTEM_COLORS : HIGHLIGHT_256_COLORS)
const _current_theme = Ref{Type{<:Highlights.AbstractTheme}}(Highlights.Themes.MonokaiMiniTheme)

set_theme(theme::Type{<:Highlights.AbstractTheme}) = _current_theme[] = theme
set_highlight(opt::HighlightOption) = _syntax_highlighting[] = opt

function Format.render(io::IO, ::MIME"text/ansi-debugger", tokens::Format.TokenIterator)
    for (str, id, style) in tokens
        fg = style.fg.active ? map(Int, (style.fg.r, style.fg.g, style.fg.b)) : nothing
        bg = style.bg.active ? map(Int, (style.bg.r, style.bg.g, style.bg.b)) : nothing
        crayon = Crayon(
            foreground = fg,
            background = bg,
            bold       = style.bold ? true : nothing,
            italics    = style.italic ? true : nothing,
            underline  = style.underline ? true : nothing,
        )
        if _syntax_highlighting[] == HIGHLIGHT_256_COLORS
            crayon = Crayons.to_256_colors(crayon)
        elseif _syntax_highlighting[] == HIGHLIGHT_SYSTEM_COLORS
            crayon = Crayons.to_system_colors(crayon)
        end
        print(io, crayon, str, inv(crayon))
    end
end

function highlight_code(code; context=nothing)
    if _syntax_highlighting[] != HIGHLIGHT_OFF
        try
            sprint(highlight, MIME("text/ansi-debugger"), code, Lexers.JuliaLexer, _current_theme[]; context=context)
        catch e
            printstyled(stderr, "failed to highlight code, $e\n"; color=Base.warn_color())
            return code
        end
    else
        return code
    end
end


const RESET = Crayon(reset = true)
function breakpoint_char(bp::BreakpointState)
    if bp.isactive
        return bp.condition === JuliaInterpreter.truecondition ? '●' : '◐'
    end
    return bp.condition === JuliaInterpreter.falsecondition ? ' ' : '○'
end

function print_sourcecode(io::IO, code::AbstractString, current_line::Integer, defline::Integer, deffile::AbstractString, breakpoint_lines::Dict{Int, BreakpointState} = Dict{Int, BreakpointState}())
    _, ext = splitext(deffile)
    if isempty(ext) || ext == ".jl"
        code = highlight_code(code; context=io)
    end
    file = SourceFile(code)
    current_offsetline = current_line - defline + 1
    checkbounds(Bool, file.offsets, current_offsetline) || return false

    startoffset, stopoffset = compute_source_offsets(code, current_offsetline, file)
    if startoffset == -1
        printstyled(io, "Line out of file range (bad debug info?)")
        return false
    end

    # Compute necessary data for line numbering
    startline = compute_line(file, startoffset)
    code = split(code[(startoffset+1):(stopoffset+1)], '\n')
    print_lines(io, code, current_line, breakpoint_lines, startline + defline - 1)
    return true
end

function print_lines(io, code, current_line, breakpoint_lines, startline)
    if !isempty(code) && all(isspace, code[end])
        pop!(code)
    end
    stopline = startline + length(code) - 1

    # Count indentation level (only count spaces for now)
    min_indentation = typemax(Int)
    for textline in code
        all(isspace, textline) && continue
        isempty(textline) && continue
        indent_line = 0
        for char in textline
            char != ' ' && break
            indent_line += 1
        end
        min_indentation = min(min_indentation, indent_line)
    end
    for i in 1:length(code)
        code[i] = code[i][min_indentation+1:end]
    end
    lineno = startline
    stoplinelength = ndigits(stopline)
    for textline in code
        break_on_line = haskey(breakpoint_lines, lineno)
        prefix = (" ", :normal)
        break_on_line           && (prefix = (breakpoint_char(breakpoint_lines[lineno]), :light_red))
        lineno == current_line  && (prefix = (">", :yellow))
        printstyled(io,
            string(prefix[1], lpad(lineno, stoplinelength), "  "),
            color = prefix[2])

        println(io, textline)
        lineno += 1
    end
    _syntax_highlighting[] == HIGHLIGHT_OFF || print(io, RESET)
    println(io)
end
