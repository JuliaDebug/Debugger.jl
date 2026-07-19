# Interactive menus (REPL.TerminalMenus) for breakpoints, frames and watch
# expressions. All of them are driven by `ActionMenu`, a generic menu where
# every row is an arbitrary object rendered by a callback and key presses map
# to actions.

function menus_available(state::DebuggerState)
    INTERACTIVE_MENUS[] || return false
    term = state.terminal
    term isa REPL.Terminals.TTYTerminal || return false
    return term.term_type != "dumb"
end

mutable struct ActionMenu <: TerminalMenus._ConfiguredMenu{TerminalMenus.Config}
    rows::Vector{Any}
    writerow::Function       # (io, row, idx) -> nothing
    onkey::Function          # (menu, key::Char, cursor_idx) -> exit::Bool
    onpick::Function         # (menu, cursor_idx) -> exit::Bool
    help::String
    cursor::Base.RefValue{Int}
    selected::Any
    color::Bool
    width::Int
    pagesize::Int
    pageoffset::Int
    config::TerminalMenus.Config
end

function ActionMenu(rows::AbstractVector; writerow::Function,
                    onkey::Function = (m, key, idx) -> false,
                    onpick::Function = (m, idx) -> true,
                    help::String = "",
                    color::Bool = true, width::Int = 80, pagesize::Int = 10)
    config = TerminalMenus.Config(charset = is_unicode() ? :unicode : :ascii)
    return ActionMenu(Vector{Any}(rows), writerow, onkey, onpick, help,
                      Ref(1), nothing, color, width,
                      clamp(length(rows), 1, pagesize), 0, config)
end

TerminalMenus.numoptions(m::ActionMenu) = length(m.rows)
TerminalMenus.header(m::ActionMenu) = m.help
TerminalMenus.cancel(m::ActionMenu) = (m.selected = nothing)
TerminalMenus.pick(m::ActionMenu, cursor::Int) = m.onpick(m, cursor)::Bool

function TerminalMenus.writeline(buf::IO, m::ActionMenu, idx::Int, iscursor::Bool)
    io = IOContext(buf, :color => m.color, :displaysize => (24, m.width))
    m.writerow(io, m.rows[idx], idx)
    return nothing
end

function TerminalMenus.keypress(m::ActionMenu, key::UInt32)
    isempty(m.rows) && return true
    return m.onkey(m, Char(key), clamp(m.cursor[], 1, length(m.rows)))::Bool
end

# Remove a row while the menu is showing. Returns `true` (exit the menu) when
# no rows are left.
function delete_row!(m::ActionMenu, idx::Int)
    deleteat!(m.rows, idx)
    nrows = length(m.rows)
    m.cursor[] = clamp(m.cursor[], 1, max(nrows, 1))
    m.pageoffset = clamp(m.pageoffset, 0, max(nrows - m.pagesize, 0))
    return nrows == 0
end

function run_menu(menu::ActionMenu, state::DebuggerState; cursor::Int = 1)
    menu.cursor[] = clamp(cursor, 1, max(length(menu.rows), 1))
    return TerminalMenus.request(state.terminal, menu; cursor = menu.cursor)
end

# Truncate `str` to a display width of `width`, appending an ellipsis when
# truncated. Menu rows must be single printable lines or TerminalMenus'
# redraw accounting breaks, so control characters are replaced/removed.
function trunc_to_width(str::AbstractString, width::Int)
    sanitized = map(c -> (c == '\n' || c == '\r' || c == '\t') ? ' ' : c, String(str))
    sanitized = filter(!Base.iscntrl, sanitized)
    textwidth(sanitized) <= width && return sanitized
    ell = ellipsis()
    budget = width - textwidth(ell)
    if budget < 0
        # no room for the ellipsis marker, hard-cut instead
        ell = ""
        budget = max(width, 0)
    end
    out = IOBuffer()
    w = 0
    for c in sanitized
        cw = textwidth(c)
        w + cw > budget && break
        write(out, c)
        w += cw
    end
    print(out, ell)
    return String(take!(out))
end

menu_settings(state::DebuggerState) = begin
    io = output_stream(state)
    (color = get(io, :color, false), width = safe_displaysize(io)[2])
end

# --- breakpoint menu ---------------------------------------------------------

bp_status_char(enabled::Bool, has_condition::Bool) =
    enabled ? (has_condition ? char_bp_conditional() : char_bp_enabled()) : char_bp_disabled()

function bp_menu_writerow(io::IO, row, idx::Int)
    width = displaysize(io)[2]
    if row === :error || row === :throw
        flag = row === :error ? JuliaInterpreter.break_on_error[] : JuliaInterpreter.break_on_throw[]
        printstyled(io, bp_status_char(flag, false); color = flag ? :light_red : :light_black)
        print(io, " break on ", row)
    else
        bp = row::JuliaInterpreter.AbstractBreakpoint
        enabled = bp.enabled[]
        printstyled(io, bp_status_char(enabled, bp.condition !== nothing);
                    color = enabled ? :light_red : :light_black)
        print(io, " ", idx, "] ", trunc_to_width(sprint(show, bp), width - 12))
    end
end

function bp_menu_toggle(row)
    if row === :error
        JuliaInterpreter.break_on_error[] ? JuliaInterpreter.break_off(:error) : JuliaInterpreter.break_on(:error)
    elseif row === :throw
        JuliaInterpreter.break_on_throw[] ? JuliaInterpreter.break_off(:throw) : JuliaInterpreter.break_on(:throw)
    else
        bp = row::JuliaInterpreter.AbstractBreakpoint
        bp.enabled[] ? JuliaInterpreter.disable(bp) : JuliaInterpreter.enable(bp)
    end
    return nothing
end

bp_location(bp::JuliaInterpreter.BreakpointFileLocation) =
    (isempty(bp.abspath) ? bp.path : bp.abspath, bp.line)

function bp_location(bp::JuliaInterpreter.BreakpointSignature)
    f = bp.f
    # `bp.sig` is the full signature tuple type, including the callable type
    meth = f isa Method ? f :
        try
            bp.sig === nothing ? first(methods(f)) : which(bp.sig)
        catch
            nothing
        end
    meth === nothing && return nothing
    ret = JuliaInterpreter.whereis(meth)
    ret === nothing && return nothing
    file, defline = ret
    return (file, bp.line == 0 ? defline : bp.line)
end

bp_location(::Any) = nothing

function breakpoint_menu(state::DebuggerState)
    open_target = Ref{Any}(nothing)
    add_requested = Ref(false)
    cursor = 1

    onkey = function (m, key, idx)
        row = m.rows[idx]
        if key == ' ' || key == 't'
            bp_menu_toggle(row)
        elseif (key == 'd' || key == 'x') && row isa JuliaInterpreter.AbstractBreakpoint
            JuliaInterpreter.remove(row)
            return delete_row!(m, idx)
        elseif key == 'a'
            # adding needs a free-form location; leave the menu, prompt for
            # one line and reopen
            add_requested[] = true
            return true
        elseif key == 'o' && row isa JuliaInterpreter.AbstractBreakpoint
            loc = bp_location(row)
            if loc !== nothing
                open_target[] = loc
                return true
            end
        end
        return false
    end
    onpick = function (m, idx)
        bp_menu_toggle(m.rows[idx])
        return false
    end

    while true
        rows = Any[JuliaInterpreter.breakpoints()...]
        push!(rows, :error, :throw)
        add_requested[] = false

        menu = ActionMenu(rows; writerow = bp_menu_writerow, onkey = onkey, onpick = onpick,
                          help = "[space/enter] toggle  [a] add  [d] delete  [o] open  [q] quit",
                          menu_settings(state)...)
        run_menu(menu, state; cursor = cursor)

        add_requested[] || break
        io = output_stream(state)
        printstyled(io, "bp add> "; color = :light_black)
        input = try
            strip(readline(state.terminal.in_stream))
        catch
            ""
        end
        isempty(input) || add_breakpoint!(state, String(input))
        # reopen with the cursor on the last (newly added) breakpoint
        cursor = max(length(JuliaInterpreter.breakpoints()), 1)
    end

    if open_target[] !== nothing
        file, line = open_target[]
        if isfile(file)
            InteractiveUtils.edit(file, line)
        else
            printstyled(stderr, "Could not find file: $(repr(file))\n"; color=Base.error_color())
        end
    end
    return nothing
end

# --- frame menu --------------------------------------------------------------

function frame_menu(state::DebuggerState)
    frames = Frame[]
    fr = state.frame
    while fr !== nothing
        push!(frames, fr)
        fr = caller(fr)
    end

    writerow = function (io, frame, idx)
        width = displaysize(io)[2]
        desc = string("[", idx, "] ", locdesc(frame; current_line=true))
        print(io, trunc_to_width(desc, width - 16))
        idx == state.level && printstyled(io, " (current)"; color=:light_black)
    end
    onpick = (m, idx) -> (m.selected = idx; true)

    menu = ActionMenu(frames; writerow = writerow, onpick = onpick,
                      help = "[enter] select frame  [q] quit",
                      menu_settings(state)...)
    return run_menu(menu, state; cursor = 1)
end

# --- watch menu --------------------------------------------------------------

function watch_menu(state::DebuggerState)
    frame = active_frame(state)
    # Evaluate once up front; watch expressions may have side effects, so they
    # should not be re-evaluated on every redraw of the menu (or by the caller
    # printing the list after the menu closes).
    rows = Any[(expr, eval_watch_expr(frame, expr)) for expr in state.watch_list]

    writerow = function (io, row, idx)
        width = displaysize(io)[2]
        expr, (res_str, errored) = row
        print(io, idx, "] ", trunc_to_width(string(expr), max(width ÷ 3, 8)), ": ")
        str = trunc_to_width(res_str, width ÷ 2)
        errored ? printstyled(io, str; color=Base.error_color()) : print(io, str)
    end
    onkey = function (m, key, idx)
        if key == 'd' || key == 'x'
            clear_watch_list!(state, idx)
            return delete_row!(m, idx)
        end
        return false
    end

    menu = ActionMenu(rows; writerow = writerow, onkey = onkey,
                      help = "[d] delete  [q] quit",
                      menu_settings(state)...)
    run_menu(menu, state)
    return menu.rows
end
