
struct Suppressed{T}
    item::T
end
Base.show(io::IO, x::Suppressed) = print(io, "<suppressed ", x.item, '>')

function print_var(io::IO, var::JuliaInterpreter.Variable)
    print(io, "  | ")
    T = typeof(var.value)
    local val
    try
        val = repr(var.value)
        if length(val) > 150
            val = Suppressed("$(length(val)) bytes of output")
        end
    catch
        val = Suppressed("printing error")
    end
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
    expr = pattern_match_kw_call(expr)
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
    print(io, highlight_code(string(expr); context=io))
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
        data = if isa(loc, BufferLocInfo)
                loc.data
            else
                read(loc.filepath, String)
            end
        breakpoint_lines = breakpoint_linenumbers(frame)
        print_sourcecode(outbuf, data, loc.line, loc.defline, loc.endline, breakpoint_lines)
    else
        print_codeinfo(outbuf, frame)
    end
    print_next_expr(outbuf, frame)
    print(io, String(take!(outbuf.io)))
end

const NUM_SOURCE_LINES_UP_DOWN = Ref(5)

function print_codeinfo(io::IO, frame::Frame)
    buf = IOBuffer()
    src = frame.framecode.src
    show(buf, src)
    active_line = convert(Int, frame.pc[])

    code = filter!(split(String(take!(buf)), '\n')) do line
        !(line == "CodeInfo(" || line == ")" || isempty(line))
    end
    startline, endline = max(1, active_line - NUM_SOURCE_LINES_UP_DOWN[] + 1), min(length(code), active_line + NUM_SOURCE_LINES_UP_DOWN[]-1)
    code = code[startline:endline]
    code .= replace.(code, Ref(r"\$\(QuoteNode\((.+?)\)\)" => s"\1"))
    breakpoint_lines = breakpoint_linenumbers(frame; lowered=true)
    print_lines(io, code, active_line, breakpoint_lines, startline)
end

"""
Determine the offsets in the source code to print, based on the offset of the
currently highlighted part of the code, and the start and stop line of the
entire function.
"""
function compute_source_offsets(code::String, offset::Integer, startline::Integer, stopline::Integer; file::SourceFile = SourceFile(code))
    offsetline = compute_line(file, offset)
    if offsetline - NUM_SOURCE_LINES_UP_DOWN[] > length(file.offsets) || startline > length(file.offsets)
        return -1, -1
    end
    startoffset = max(file.offsets[max(offsetline - NUM_SOURCE_LINES_UP_DOWN[] + 1, 1)], startline == 0 ? 0 : file.offsets[startline])
    stopoffset = lastindex(code)-1
    if offsetline + NUM_SOURCE_LINES_UP_DOWN[] < lastindex(file.offsets)
        stopoffset = min(stopoffset, file.offsets[offsetline + NUM_SOURCE_LINES_UP_DOWN[]] - 1)
    end
    if stopline + 1 <= lastindex(file.offsets)
        stopoffset = min(stopoffset, file.offsets[stopline + 1] - 1)
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
const _current_theme = Ref{Type{<:Highlights.AbstractTheme}}(Highlights.Themes.MonokaiTheme)

set_theme(theme::Type{<:Highlights.AbstractTheme}) = _current_theme[] = theme
set_highlight(opt::HighlightOption) = _syntax_highlighting[] = opt

function Format.render(io::IO, ::MIME"text/ansi-debugger", tokens::Format.TokenIterator)
    for (str, id, style) in tokens
        fg = style.fg.active ? map(Int, (style.fg.r, style.fg.g, style.fg.b)) : :nothing
        bg = style.bg.active ? map(Int, (style.bg.r, style.bg.g, style.bg.b)) : :nothing
        crayon = Crayon(
            foreground = fg,
            background = bg,
            bold       = style.bold ? true : :nothing,
            italics    = style.italic ? true : :nothing,
            underline  = style.underline ? true : :nothing,
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
        return sprint(highlight, MIME("text/ansi-debugger"), code, Lexers.JuliaLexer, _current_theme[]; context=context)
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

function print_sourcecode(io::IO, code::String, line::Integer, defline::Integer, endline::Integer, breakpoint_lines::Dict{Int, BreakpointState} = Dict{Int, BreakpointState}())
    code = highlight_code(code; context=io)
    file = SourceFile(code)
    stopline = min(endline, line + NUM_SOURCE_LINES_UP_DOWN[])
    startoffset, stopoffset = compute_source_offsets(code, file.offsets[line], defline, stopline; file=file)

    if startoffset == -1
        printstyled(io, "Line out of file range (bad debug info?)")
        return
    end

    # Compute necessary data for line numbering
    startline = compute_line(file, startoffset)

    code = split(code[(startoffset+1):(stopoffset+1)],'\n')
    print_lines(io, code, line, breakpoint_lines, startline)
end

function print_lines(io, code, current_line, breakpoint_lines, startline)
    if !isempty(code) && isempty(code[end])
        pop!(code)
    end
    stopline = startline + length(code) - 1

    # Count indentation level (only count spaces for now)
    min_indentation = typemax(Int)
    for textline in code
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
