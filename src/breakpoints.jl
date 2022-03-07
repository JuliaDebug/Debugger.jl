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
    f = getfield(m, f)
    return (f isa Function || f isa Type) ? f : nothing
end

function add_breakpoint!(state::DebuggerState, cmd::AbstractString)
    cmd = strip(cmd)
    bp_error() = (@error "Empty breakpoint expression"; false)
    bp_error(err) = (@error err; false)
    undef_func(m, expr) = bp_error("Expression $(expr) in " * (m !== Main ? "$m or"  : "") * " Main did not evaluate to a function or type")
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
    if isexpr(location_expr, :call) && location_expr.args[1] == :(:)
        line = location_expr.args[3]
        line isa Integer || return bp_error("line number to the right of `:` should be given as an integer")
        location_expr = location_expr.args[2]
    end

    # File
    if location_expr isa String
        file = location_expr
        if line === nothing
            return bp_error("breakpoints in files need a line number")
        end
        @info "added breakpoint at $file:$line"
        breakpoint(file, line, cond_expr)
        return true
    end

    f = nothing
    if location_expr isa Symbol || location_expr isa Expr
        m = moduleof(frame)
        has_args = false
        if location_expr isa Symbol
            f = get_function_in_module_or_Main(m, location_expr)
        else
            expr = location_expr
            if isexpr(expr, :call)
                has_args = true
                expr = expr.args[1]
            end
            for m in (moduleof(frame), Main)
                try
                    f_eval = Base.eval(m, expr)
                    if f_eval isa Function || f_eval isa Type
                        f = f_eval
                        break
                    end
                catch e
                    bp_error("error when evaluating expression $(expr) in module $m")
                end
            end
        end
        f === nothing && return undef_func(m, location_expr)
        if !has_args
            @info string("added breakpoint for ", f isa Function ? "function" : "type", " $f", (line === nothing ? "" : ":$line"))
            breakpoint(f, line, cond_expr)
            return true
        end
    end
    @label not_a_function
    if f === nothing
        location_expr isa Expr || return bp_error("failed to parse breakpoint expression")
        location_expr.head == :call || return bp_error("expected a call expression or an expression that evaluates to a function")
        m = moduleof(frame)
        f = get_function_in_module_or_Main(m, fsym)
        f === nothing && return undef_func(m, fsym)
    end

    fsym, f_args = location_expr.args[1], location_expr.args[2:end]
    type_args = false
    if any(arg -> isexpr(arg, :(::)), f_args)
        if !all(arg -> arg.head == :(::), f_args)
            return bp_error("all arguments should have `::` if one does")
        end
        f_args = [arg.args[1] for arg in f_args]
        type_args = true
    end

    locals = filter(v -> v.name != Symbol(""), JuliaInterpreter.locals(frame))

    res = nothing
    arg_types = []
    for arg in f_args
        for m in (moduleof(frame), Main)
            try 
                res = interpret_variable(arg, locals, m)
            catch e
                e isa UndefVarError || rethrow()
            end
        end
        if res === nothing
            return bp_error("could not find function argument $arg")
        end
        push!(arg_types, type_args ? res : typeof(res))
    end

    breakpoint(f, Tuple(arg_types), something(line, 0), cond_expr)

    @info "added breakpoint for method $f(" * join("::" .* string.(arg_types), ", ") * ")"
    return true
end

function interpret_variable(arg, locals, m::Module)
    eval_expr = Expr(:let,
        Expr(:block,
            map(x->Expr(:(=), x...), [(v.name, maybe_quote(v.value)) for v in locals])...),
        Expr(:block, arg)
        )
    return Core.eval(m, eval_expr)
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
