
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

print_locdesc(io::IO, frame::Frame) = println(io, locdesc(frame))

function print_locals(io::IO, frame::Frame)
    vars = JuliaInterpreter.locals(frame)
    for var in vars
        # Hide gensymmed variables
        startswith(string(var.name), "#") && continue
        print_var(io, var)
    end
end

function print_frame(io::IO, num::Integer, frame::Frame)
    print(io, "[$num] ")
    print_locdesc(io, frame)
    print_locals(io, frame)
end


function print_next_expr(io::IO, frame::Frame)
    maybe_quote(x) = (isa(x, Expr) || isa(x, Symbol)) ? QuoteNode(x) : x
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

function print_status(io::IO, frame::Frame)
    # Buffer to avoid flickering
    outbuf = IOContext(IOBuffer(), io)
    printstyled(outbuf, "In ", locdesc(frame), "\n"; color=:bold)
    loc = locinfo(frame)

    if loc !== nothing
        data = if isa(loc, BufferLocInfo)
                loc.data
            else
                read(loc.filepath, String)
            end
        print_sourcecode(outbuf, data, loc.line, loc.defline)
    else
        print_codeinfo(outbuf, frame)
    end
    print_next_expr(outbuf, frame)
    print(io, String(take!(outbuf.io)))
end

function print_codeinfo(io::IO, frame::Frame)
    buf = IOBuffer()
    src = frame.framecode.src
    show(buf, src)
    active_line = convert(Int, frame.pc[])

    code = filter!(split(String(take!(buf)), '\n')) do line
        !(line == "CodeInfo(" || line == ")" || isempty(line))
    end

    code .= replace.(code, Ref(r"\$\(QuoteNode\((.+?)\)\)" => s"\1"))

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


const NUM_SOURCE_LINES_UP_DOWN = Ref(5)

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
    startoffset = max(file.offsets[max(offsetline - NUM_SOURCE_LINES_UP_DOWN[], 1)], startline == 0 ? 0 : file.offsets[startline])
    stopoffset = lastindex(code)-1
    if offsetline + NUM_SOURCE_LINES_UP_DOWN[] < lastindex(file.offsets)
        stopoffset = min(stopoffset, file.offsets[offsetline + NUM_SOURCE_LINES_UP_DOWN[]] - 1)
    end
    if stopline + 1 < lastindex(file.offsets)
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

const _syntax_highlighting = Ref(HIGHLIGHT_SYSTEM_COLORS)
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

function print_sourcecode(io::IO, code::String, line::Integer, defline::Integer)
    code = highlight_code(code; context=io)
    file = SourceFile(code)
    startoffset, stopoffset = compute_source_offsets(code, file.offsets[line], defline, line+NUM_SOURCE_LINES_UP_DOWN[]; file=file)

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

    # Count indentation level (only count spaces for now)
    min_indentation = typemax(Int)
    for textline in code
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

    for textline in code
        printstyled(io,
            string(rpad(lineno, stoplinelength), "  ");
            color = lineno == current_line ? :yellow : :bold)
        println(io, textline)
        lineno += 1
    end
    _syntax_highlighting[] == HIGHLIGHT_OFF || print(io, RESET)
    println(io)
end
