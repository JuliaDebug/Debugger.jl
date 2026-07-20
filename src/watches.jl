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

# Evaluate a watch expression in the context of `frame`.
# Returns `(result_string, errored)`.
function eval_watch_expr(frame::Frame, expr)
    vars = filter(v -> v.name != Symbol(""), JuliaInterpreter.locals(frame))
    eval_expr = Expr(:let,
        Expr(:block, map(x->Expr(:(=), x...), [(v.name, maybe_quote(v.value)) for v in vars])...),
        expr)
    res = try
        Core.eval(moduleof(frame), eval_expr)
    catch err
        # `showerror` instead of `show`: the message is what matters, and the
        # raw exception struct can contain unstable fields (e.g. world ages)
        msg = try
            first(split(sprint(showerror, err), '\n'))
        catch
            "error while printing the thrown error"
        end
        return String(msg), true
    end
    return repr_limited(res, 512), false
end

function print_watch_entry(io::IO, i::Integer, expr, res_str::AbstractString, errored::Bool)
    expr_str = highlight_code(string(expr); context=io) # Should maybe use repr here in some cases (strings)
    if errored
        res_str = sprint((io, args...) -> printstyled(io, args...; color=Base.error_color()), res_str; context=io)
    else
        res_str = highlight_code(res_str, context=io)
    end
    printstyled(io, "  w$i] "; color=:light_black)
    println(io, "$(expr_str): $(res_str)")
end

function show_watch_list(io::IO, state::DebuggerState)
    frame = active_frame(state)
    for (i, expr) in enumerate(state.watch_list)
        res_str, errored = eval_watch_expr(frame, expr)
        print_watch_entry(io, i, expr, res_str, errored)
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
