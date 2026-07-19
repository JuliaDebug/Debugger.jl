suppressed(str) = string("<", str, "...>")

function safe_displaysize(io::IO)
    try
        return displaysize(io)
    catch
        return (24, 80)
    end
end

# `val` is an arbitrary user value: without `@nospecialize` this method (and
# inference through the `show` machinery below it) recompiles for every new
# value type that shows up in the variable display
function repr_limited(@nospecialize(val), n, f=show)
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

# --- variable display --------------------------------------------------------

struct VariableEntry
    lhs::String      # "name" or "name::T" depending on the type display mode
    value::Any
    show_value::Bool
    tag::String      # "arg", "param", "captured" or ""
end

variable_name_string(name::Symbol) =
    Base.isidentifier(name) ? string(name) : string("var\"", name, "\"")

function type_string(@nospecialize(T))
    str = try
        string(T)
    catch
        "?"
    end
    if VARIABLE_TYPES[] === :compact && length(str) > TYPE_COMPACT_THRESHOLD[]
        i = findfirst(==('{'), str)
        i !== nothing && (str = string(str[1:i], ellipsis(), "}"))
    end
    return str
end

function variable_entries(frame::Frame; mode::Symbol = VARIABLE_TYPES[])
    vars = JuliaInterpreter.Variable[]
    for var in JuliaInterpreter.locals(frame)
        # Hide gensymmed variables and the nameless self slot of keyword-body methods
        name = string(var.name)
        (startswith(name, "#") || isempty(name)) && continue
        push!(vars, var)
    end

    # Arguments (in signature order) first, then type parameters, then locals
    scope = frame.framecode.scope
    argnames = scope isa Method ? frame.framecode.src.slotnames[2:scope.nargs] : Symbol[]
    isarg(v) = !v.isparam && v.name in argnames
    args = [v for v in vars if isarg(v)]
    # In keyword-body methods the keyword arguments come before the nameless
    # boundary slot; order them after the positional arguments, like in the
    # printed signature
    boundary = findfirst(==(Symbol("")), argnames)
    function argorder(name)
        i = something(findfirst(==(name), argnames), typemax(Int))
        return boundary !== nothing && i < boundary ? i + length(argnames) : i
    end
    sort!(args; by = v -> argorder(v.name))
    params = [v for v in vars if v.isparam]
    rest = [v for v in vars if !isarg(v) && !v.isparam]

    entries = VariableEntry[]
    for v in vcat(args, params, rest)
        name = variable_name_string(v.name)
        tag = isarg(v) ? "arg" :
              v.isparam ? "param" :
              v.is_captured_closure ? "captured" : ""
        # Type parameters are types; showing `T::DataType = Float64` is noise
        if v.isparam || mode === :none
            lhs = name
        else
            lhs = string(name, "::", type_string(typeof(v.value)))
        end
        show_value = mode !== :types || v.isparam
        push!(entries, VariableEntry(lhs, v.value, show_value, tag))
    end
    return entries
end

function print_var_entry(io::IO, e::VariableEntry, lhs_width::Int, width::Int)
    tagstr = isempty(e.tag) ? "" : string("(", e.tag, ")")
    line = string("  ", rpad(e.lhs, lhs_width))
    if e.show_value
        budget = clamp(width - textwidth(line) - textwidth(tagstr) - 5, 20, 512)
        val = repr_limited(e.value, budget)
        line = string(line, " = ", val)
    end
    print(io, highlight_code(line; context=io))
    if !isempty(tagstr)
        printstyled(io, "  ", tagstr; color=:light_black)
    end
    println(io)
end

"""
    print_locals(io, frame; limit=typemax(Int)) -> number of entries printed
"""
function print_locals(io::IO, frame::Frame; limit::Integer = typemax(Int))
    entries = variable_entries(frame)
    isempty(entries) && return 0
    width = safe_displaysize(io)[2]
    lhs_width = min(maximum(e -> textwidth(e.lhs), entries), 40)
    nshown = min(length(entries), limit)
    for e in entries[1:nshown]
        print_var_entry(io, e, lhs_width, width)
    end
    if nshown < length(entries)
        printstyled(io, "  ", ellipsis(), " and ", length(entries) - nshown,
                    " more variables (`fr` to list all)\n"; color=:light_black)
    end
    return nshown
end

# Full `text/plain` display of a single variable, as used by `p x`
function print_var_rich(io::IO, var::JuliaInterpreter.Variable; mod::Union{Module,Nothing}=nothing)
    ds = safe_displaysize(io)
    # Inherit the properties of `io` (:color, :module, custom display keys) so
    # values display like they would at the REPL
    show_full = function (io_, v)
        ioc = IOContext(IOContext(io_, io), :limit => true, :displaysize => ds)
        mod !== nothing && (ioc = IOContext(ioc, :module => mod))
        show(ioc, MIME"text/plain"(), v)
    end
    valstr = repr_limited(var.value, 16384, show_full)
    name = variable_name_string(var.name)
    print(io, highlight_code(name; context=io))
    println(io, " = ", valstr)
end

function print_frame_header(io::IO, frame::Frame; level=nothing, depth=nothing, current_line::Bool=false)
    if level === nothing
        printstyled(io, "In "; bold=true)
    elseif depth === nothing
        printstyled(io, "[", level, "] "; bold=true)
    else
        printstyled(io, "[", level, "/", depth, "] "; bold=true)
    end
    print(io, highlight_code(frame_signature(frame); context=io))
    printstyled(io, " at ", frame_location(frame; current_line=current_line); color=:light_black)
    println(io)
end

function print_frame(io::IO, num::Integer, frame::Frame; current_line=false)
    print_frame_header(io, frame; level=num, current_line=current_line)
    print_locals(io, frame)
end

function pattern_match_kw_call(expr)
    if isexpr(expr, :call)
        f = string(expr.args[1])
        is_kw = expr.args[1] === Core.kwcall ||
            occursin("#kw#", f) || (startswith(f, "#") && endswith(f, "_kw"))
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

append_any(@nospecialize x...) = append!([], Core.svec((x...)...))

function pattern_match_apply_call(expr, frame)
    if !(isexpr(expr, :call) && expr.args[1] == Core._apply)
        return expr
    end
    args = Any[lookup(frame, expr.args[i+2]) for i in 1:(length(expr.args)-2)]
    new_expr = Expr(:call, expr.args[2])
    argsflat = append_any(args...)
    for x in argsflat
        push!(new_expr.args, (isa(x, Symbol) || isa(x, Expr) || isa(x, QuoteNode)) ? QuoteNode(x) : x)
    end
    return new_expr
end

# Replace functions with their symbol so that calls print like `f(x)` instead of `(f)(x)`,
# and function arguments do not gain a version-dependent `Main.` qualification.
function replace_function_with_symbol(expr)
    if isexpr(expr, :call)
        for i in eachindex(expr.args)
            arg = expr.args[i]
            arg isa Function || continue
            s = Symbol(arg)
            if Base.isidentifier(s)
                expr.args[i] = s
            end
        end
    end
    return expr
end

function expression_for_display(frame::Frame)
    expr = pc_expr(frame)
    if expr isa GlobalRef && frame.pc < nstatements(frame.framecode)
        # Julia 1.12 may pause on a global lookup followed by separate argument
        # loads and then a call. Preview that call so the status still shows the
        # call rather than just `Main.:+` — both when the global is the callee
        # and when it is an argument (e.g. pausing on `Base.Math.:*` inside
        # a call like `map(*, x, y)`).
        for next_pc in (frame.pc + 1):nstatements(frame.framecode)
            stmt = pc_expr(frame, next_pc)
            call = isexpr(stmt, :(=)) ? stmt.args[2] : stmt
            if isexpr(call, :call)
                any(a -> a isa JuliaInterpreter.SSAValue && a.id == frame.pc, call.args) || return expr
                call = copy(call)
                for i in eachindex(call.args)
                    arg = call.args[i]
                    # Substitute the loads that have not run yet; SSA values
                    # computed before `frame.pc` are resolved by `lookup` in
                    # `print_next_expr`
                    if arg isa JuliaInterpreter.SSAValue && frame.pc <= arg.id < next_pc
                        source = pc_expr(frame, arg.id)
                        if source isa Union{GlobalRef, JuliaInterpreter.SlotNumber, QuoteNode}
                            call.args[i] = source
                        else
                            return expr
                        end
                    end
                end
                return call
            end

            stmt isa Union{GlobalRef, JuliaInterpreter.SlotNumber, QuoteNode} || break
        end
    end
    return expr
end

function print_next_expr(io::IO, frame::Frame)
    expr = expression_for_display(frame)
    @assert expr !== nothing
    printstyled(io, next_expr_marker(), " "; color=:light_black, bold=true)
    isa(expr, Expr) && (expr = copy(expr))
    if isexpr(expr, :(=))
        expr = expr.args[2]
    end
    if expr isa QuoteNode && !isa(expr.value, Union{Symbol, Expr})
        # A function breakpoint can stop on a bare quoted value (e.g. the
        # callee); show the value itself rather than `$(QuoteNode(f))` (#352)
        expr = expr.value
    end
    if isexpr(expr, :call) || isexpr(expr, :return)
        for i in 1:length(expr.args)
            val = try
                lookup(frame, expr.args[i])
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
                lookup(frame, expr.val)
            catch err
                err isa UndefVarError || rethrow(err)
                expr.val
            end
            expr = Expr(:return, maybe_quote(val))
        end
    end
    expr = pattern_match_kw_call(expr)
    expr = pattern_match_apply_call(expr, frame)
    expr = replace_function_with_symbol(expr)
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

function print_code_section(io::IO, frame::Frame; force_lowered=false)
    loc = locinfo(frame)
    if loc !== nothing && !force_lowered
        defline, deffile, current_line, body = loc
        breakpoint_lines = breakpoint_linenumbers(frame)
        ok = print_sourcecode(io, body, current_line, defline, deffile, breakpoint_lines)
        if !ok
            printstyled(io, "failed to lookup source code, showing lowered code:\n"; color=Base.warn_color())
            print_codeinfo(io, frame)
        end
    else
        print_codeinfo(io, frame)
    end
end

# Buffer writes (to avoid flickering) while keeping the properties and the
# display size of the underlying io
status_buffer(io::IO) = (buf = IOBuffer();
    (buf, IOContext(IOContext(buf, io), :displaysize => safe_displaysize(io))))

function print_status(io::IO, frame::Frame; force_lowered=false)
    buf, outbuf = status_buffer(io)
    print_frame_header(outbuf, frame)
    print_code_section(outbuf, frame; force_lowered=force_lowered)
    print_next_expr(outbuf, frame)
    print(io, String(take!(buf)))
end

function print_status(io::IO, state::DebuggerState)
    frame = active_frame(state)
    buf, outbuf = status_buffer(io)
    print_frame_header(outbuf, frame; level=state.level, depth=stacklength(state.frame), current_line=true)
    print_code_section(outbuf, frame; force_lowered=state.lowered_status)
    if MAX_VARS_IN_STATUS[] > 0
        nprinted = print_locals(outbuf, frame; limit=MAX_VARS_IN_STATUS[])
        nprinted > 0 && println(outbuf)
    end
    if !isempty(state.watch_list)
        show_watch_list(outbuf, state)
        println(outbuf)
    end
    print_next_expr(outbuf, frame)
    print(io, String(take!(buf)))
end

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

# `Highlights.highlight` creates a tree-sitter parser and compiles the
# highlight query on every call (~30 ms) — far too slow for a status print
# that highlights every variable line. Cache them for the session.
mutable struct HighlightCache
    parser::Any
    query::Any
    theme::Any
    theme_name::String
end
const _highlight_cache = Ref{Union{HighlightCache, Nothing}}(nothing)

function highlight_cache()
    cache = _highlight_cache[]
    if cache === nothing || cache.theme_name != _current_theme[]
        lang = Highlights.resolve_language(:julia)
        parser = Highlights.TreeSitter.Parser(lang)
        query = Highlights.TreeSitter.Query(lang, ["highlights"])
        theme = Highlights.load_theme(_current_theme[])
        cache = HighlightCache(parser, query, theme, _current_theme[])
        _highlight_cache[] = cache
    end
    return cache
end

function highlight_code(code; context=nothing)
    if context !== nothing && !get(context, :color, false)
        return code
    end
    _syntax_highlighting[] || return code
    try
        cache = highlight_cache()
        tokens = Highlights.highlight_tokens(cache.parser, cache.query, code)
        return sprint(context=context) do io
            Highlights.format(io, MIME("text/ansi"), tokens, code, cache.theme, :julia)
        end
    catch
        # The fast path uses Highlights internals; fall back to the public API
        # if they change
        try
            return sprint(highlight, MIME("text/ansi"), code, :julia, _current_theme[]; context=context)
        catch e
            printstyled(stderr, "failed to highlight code, $e\n"; color=Base.warn_color())
            return code
        end
    end
end

function breakpoint_char(bp::BreakpointState)
    if bp.isactive
        return bp.condition === JuliaInterpreter.truecondition ? char_bp_enabled() : char_bp_conditional()
    end
    return bp.condition === JuliaInterpreter.falsecondition ? ' ' : char_bp_disabled()
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

# Print `textline` emphasized (bold). The line may contain ANSI color sequences
# from syntax highlighting whose `\e[0m` resets would clear the bold attribute,
# so re-apply it after every reset.
function print_emphasized(io::IO, textline::AbstractString)
    if get(io, :color, false)
        print(io, "\e[1m", replace(textline, "\e[0m" => "\e[0m\e[1m"), "\e[0m")
    else
        print(io, textline)
    end
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
        iscurrent = lineno == current_line
        prefix = (" ", :light_black)
        break_on_line && (prefix = (breakpoint_char(breakpoint_lines[lineno]), :light_red))
        iscurrent    && (prefix = (">", :yellow))
        printstyled(io,
            string(prefix[1], lpad(lineno, stoplinelength), "  "),
            color = prefix[2])

        if iscurrent
            print_emphasized(io, textline)
            println(io)
        else
            println(io, textline)
        end
        lineno += 1
    end
    println(io)
end
