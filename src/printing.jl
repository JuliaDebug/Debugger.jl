
struct Suppressed{T}
    item::T
end
Base.show(io::IO, x::Suppressed) = print(io, "<suppressed ", x.item, '>')

function print_var(io::IO, var::JuliaInterpreter.Variable)
    print("  | ")
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
    println(io, var.name, "::", T, " = ", val)
end

print_locdesc(io::IO, frame::JuliaStackFrame) = println(io, locdesc(frame))

function print_locals(io::IO, frame::JuliaStackFrame)
    vars = JuliaInterpreter.locals(frame)
    for var in vars
        # Hide gensymmed variables
        startswith(string(var.name), "#") && continue
        print_var(io, var)
    end
end

function print_frame(io::IO, num::Integer, frame::JuliaStackFrame)
    print(io, "[$num] ")
    print_locdesc(io, frame)
    print_locals(io, frame)
end

function print_next_state(io::IO, frame::JuliaStackFrame)
    maybe_quote(x) = (isa(x, Expr) || isa(x, Symbol)) ? QuoteNode(x) : x

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

print_status(io::IO, state::DebuggerState) = print_status(io, active_frame(state))
function print_status(io::IO, frame::JuliaStackFrame)
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
        print_sourcecode(outbuf, data,
            loc.line, loc.defline)
    else
        print_codeinfo(outbuf, frame)
    end
    print_next_state(outbuf, frame)
    print(io, String(take!(outbuf.io)))
end

function print_codeinfo(io::IO, frame::JuliaStackFrame)
    buf = IOBuffer()
    src = frame.code.code
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