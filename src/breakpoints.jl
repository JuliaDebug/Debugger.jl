function parse_as_much_as_possible(str::AbstractString, startidx)
    # This should be doable in a better way
    l = lastindex(str)
    idx = startidx
    expr = nothing
    offset = startidx
    while idx <= l
        s = SubString(str, startidx, idx)
        maybe_expr, maybe_offset = Meta.parse(s, 1; raise=false, greedy=true, depwarn=false)
        if !isa(maybe_expr, Expr) || !(maybe_expr.head == :error || maybe_expr.head ==:incomplete)
            expr = maybe_expr
            offset = maybe_offset
        end
        idx = nextind(str, idx)
    end
    return expr, offset
end

function get_function_in_module_or_Main(m::Module, f::Symbol)
    if !isdefined(m, f)
        !isdefined(Main, f) && return nothing
        m = Main
    end
    return getfield(m, f)
end

function add_breakpoint!(state::DebuggerState, cmd::AbstractString)
    cmd = strip(cmd)
    bp_error(err) = (printstyled(stderr, err, "\n", color = Base.error_color()); false)
    undef_func(m, f) = bp_error("function $f in " * (m !== Main ? "$m or"  : "") * " Main not defined")
    isempty(cmd) && return bp_error()
    frame = active_frame(state)

    location_expr, offset = parse_as_much_as_possible(cmd, 1)
    location_expr === nothing && return bp_error("failed to parse breakpoint expression")
    cond_expr, _ = parse_as_much_as_possible(cmd, offset)

    # Check if it is just a number, in that case, breakpoint is at current file
    if location_expr isa Integer
        line = location_expr
        ret = JuliaInterpreter.whereis(frame)
        if ret === nothing
            return bp_error("could not determine location info of current frame")
        end
        current_file, current_line = ret
        breakpoint(current_file, line, cond_expr)
        return true
    end
 
    line = nothing
    if location_expr isa Expr && location_expr.head == :call && location_expr.args[1] == :(:)
        line = location_expr.args[3]
        line isa Integer || return bp_error("line number to the right of `:` should be given as an integer")
        location_expr = location_expr.args[2]
    end

    # Function
    if location_expr isa String
        file = location_expr
        if line === nothing
            return bp_error("breakpoints in files need a line number")
        end
        @info "added breakpoint at $file:$line"
        breakpoint(file, line, cond_expr)
        return true
    end

    if location_expr isa Symbol
        fsym = location_expr
        m = moduleof(frame)
        f = get_function_in_module_or_Main(m, fsym)
        f == nothing && return undef_func(m, fsym)
        @info "added breakpoint for function $f" * (line === nothing ? "" : ":$line")
        breakpoint(f, line, cond_expr)
        return true
    end

    location_expr isa Expr || return bp_error("failed to parse breakpoint expression")
    location_expr.head == :call || return bp_error("expected a call expression")
    
    fsym, f_args = location_expr.args[1], location_expr.args[2:end]
    type_args = false
    if any(arg -> arg isa Expr && arg.head == :(::), f_args)
        if !all(arg -> arg.head == :(::), f_args)
            return bp_error("all arguments should have `::` if one does")
        end
        f_args = [arg.args[1] for arg in f_args]
        type_args = true
    end

    vars = filter(v -> v.name != Symbol(""), JuliaInterpreter.locals(frame))
    eval_expr = Expr(:let,
        Expr(:block, 
            map(x->Expr(:(=), x...), [(v.name, maybe_quote(v.value)) for v in vars])...),
        Expr(:block,
            Expr(:tuple, [arg for arg in f_args]...))
        )
    res = Core.eval(moduleof(frame), eval_expr)
    m = moduleof(frame)
    f = get_function_in_module_or_Main(m, fsym)
    f == nothing && return undef_func(m, fsym)
    types = type_args ? res : typeof.(res)
    breakpoint(f, types, something(line, 0), cond_expr)

    @info "added breakpoint for method $f(" * join("::" .* string.(types), ", ") * ")"
    return true
end

function show_breakpoints(io::IO, state::DebuggerState)
    if JuliaInterpreter.break_on_error[] || JuliaInterpreter.break_on_throw[]
        println(io, "Breaking on ", JuliaInterpreter.break_on_throw[] ? "throw" : "error")
    end

    bps = JuliaInterpreter.breakpoints()
    if !isempty(bps)
        for (i, bp) in enumerate(bps)
            println(io, "$i] $bp")
        end
        println(io)
    end
end

function check_breakpoint_index(i)
    if !checkbounds(Bool, JuliaInterpreter.breakpoints(), i)
        printstyled(stderr, "ERROR: breakpoint $i does not exist\n"; color=Base.error_color())
        return false
    end
    return true
end

function toggle_breakpoint!(state)
    foreach(JuliaInterpreter.toggle, JuliaInterpreter.breakpoints())
    return true
end

function toggle_breakpoint!(state, i)
    check_breakpoint_index(i) || return false
    JuliaInterpreter.toggle(JuliaInterpreter.breakpoints()[i])
    return true
end

disable_breakpoint!(state) = (JuliaInterpreter.disable(); true)

function disable_breakpoint!(state, i)
    check_breakpoint_index(i) || return false
    JuliaInterpreter.disable(JuliaInterpreter.breakpoints()[i])
    return true
end

enable_breakpoint!(state) = (JuliaInterpreter.enable(); true)

function enable_breakpoint!(state, i)
    check_breakpoint_index(i) || return false
    JuliaInterpreter.enable(JuliaInterpreter.breakpoints()[i])
    return true
end

remove_breakpoint!(state::DebuggerState) = (JuliaInterpreter.remove(); true)

function remove_breakpoint!(state::DebuggerState, i::Int)
    check_breakpoint_index(i) || return false
    JuliaInterpreter.remove(JuliaInterpreter.breakpoints()[i])
    return true
end
 