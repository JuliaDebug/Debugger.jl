function add_watch_entry!(state::DebuggerState, cmd::AbstractString)
    expr = Base.parse_input_line(cmd)
    if isexpr(expr, :error) || isexpr(expr, :incomplete)
        printstyled(stderr, "ERROR: syntax: ", expr.args[1], "\n", color=Base.error_color())
        return false
    end
    isexpr(expr, :toplevel) && (expr = expr.args[end])
    push!(state.watch_list, expr)
    return true
end

function show_watch_list(io::IO, state::DebuggerState)
    frame = active_frame(state)
    for (i, expr) in enumerate(state.watch_list)
        vars = filter(v -> v.name != Symbol(""), JuliaInterpreter.locals(frame))
        eval_expr = Expr(:let,
            Expr(:block, map(x->Expr(:(=), x...), [(v.name, maybe_quote(v.value)) for v in vars])...),
            expr)
        errored = false
        res = try
            Core.eval(moduleof(frame), eval_expr)
        catch err
            errored = true
            err
        end
        expr_str = highlight_code(string(expr); context=io) # Should maybe use repr here in some cases (strings)
        if errored
            res_str = sprint((io, args...) -> printstyled(io, args...; color=Base.error_color()), res; context=io)
        else
            res_str = highlight_code(repr(res), context=io)
        end
        println(io, "$i] $(expr_str): $(res_str)")
    end
end

clear_watch_list!(state::DebuggerState) = empty!(state.watch_list)
function clear_watch_list!(state::DebuggerState, i::Int)
    if !checkbounds(Bool, state.watch_list, i)
        printstyled(stderr, "ERROR: watch entry $i does not exist\n"; color=Base.error_color())
        return
    end
    deleteat!(state.watch_list, i)
end