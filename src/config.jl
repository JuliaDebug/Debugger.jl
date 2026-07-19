# Central UI configuration. Everything here can be set through `Debugger.config`.

const _syntax_highlighting = Ref(true)
const _current_theme = Ref("Monokai Dark")
const NUM_SOURCE_LINES_UP_DOWN = Ref(4)
const MAX_BYTES_REPR = Ref(100)

# How variable types are shown in variable listings (#396):
#   :compact — type parameters of long types are elided, e.g. `Dict{…}`
#   :none    — values only
#   :types   — types only
#   :full    — the full type
const TYPE_DISPLAY_MODES = (:compact, :none, :types, :full)
const VARIABLE_TYPES = Ref{Symbol}(:compact)
const TYPE_COMPACT_THRESHOLD = Ref(24)

# Maximum number of variables shown in the automatic status display (`fr` always shows all)
const MAX_VARS_IN_STATUS = Ref(15)

# Full-screen mode: run on the terminal's alternate screen and redraw the
# status in place instead of scrolling
const STICKY = Ref(true)

const CHARSET = Ref{Symbol}(:unicode)

# Interactive TerminalMenus-based menus for `bp`, `f`, `w` and `focus`
const INTERACTIVE_MENUS = Ref(true)

set_theme(theme::String) = _current_theme[] = theme
set_highlight(opt::Bool) = _syntax_highlighting[] = opt

is_unicode() = CHARSET[] === :unicode

char_bp_enabled()     = is_unicode() ? '●' : '*'
char_bp_conditional() = is_unicode() ? '◐' : '%'
char_bp_disabled()    = is_unicode() ? '○' : 'o'
ellipsis()            = is_unicode() ? "…" : "..."
next_expr_marker()    = is_unicode() ? "→" : "next:"

"""
    Debugger.config(; kwargs...)

Query or set Debugger UI options. Called without arguments it returns the current
settings as a `NamedTuple`; keywords set the corresponding option:

- `theme::String`: syntax highlighting theme (default: `"Monokai Dark"`)
- `highlight::Bool`: syntax highlight source code and variables (default: `true`)
- `context_lines::Int`: number of source lines shown above/below the current line (default: `4`)
- `vartypes::Symbol`: how variable types are displayed, one of `:compact`, `:none`,
  `:types`, `:full` (default: `:compact`). Can be cycled with the `T` key in the debugger.
- `max_vars::Int`: maximum number of variables in the automatic status display (default: `15`)
- `sticky::Bool`: "full screen" mode — the debugger runs on the terminal's alternate
  screen (restored on quit) and redraws the status in place instead of scrolling
  (default: `true`). Can be toggled with the `S` key in the debugger.
- `charset::Symbol`: `:unicode` or `:ascii` (default: `:unicode`)
- `menus::Bool`: use interactive menus for `bp`, `f`, `w` and `focus` (default: `true`)
"""
function config(; theme::Union{Nothing,String} = nothing,
                  highlight::Union{Nothing,Bool} = nothing,
                  context_lines::Union{Nothing,Int} = nothing,
                  vartypes::Union{Nothing,Symbol} = nothing,
                  max_vars::Union{Nothing,Int} = nothing,
                  sticky::Union{Nothing,Bool} = nothing,
                  charset::Union{Nothing,Symbol} = nothing,
                  menus::Union{Nothing,Bool} = nothing)
    theme !== nothing && set_theme(theme)
    highlight !== nothing && set_highlight(highlight)
    context_lines !== nothing && (NUM_SOURCE_LINES_UP_DOWN[] = max(1, context_lines))
    if vartypes !== nothing
        vartypes in TYPE_DISPLAY_MODES ||
            throw(ArgumentError("vartypes should be one of $(TYPE_DISPLAY_MODES), got :$vartypes"))
        VARIABLE_TYPES[] = vartypes
    end
    max_vars !== nothing && (MAX_VARS_IN_STATUS[] = max(0, max_vars))
    sticky !== nothing && (STICKY[] = sticky)
    if charset !== nothing
        charset in (:unicode, :ascii) ||
            throw(ArgumentError("charset should be :unicode or :ascii, got :$charset"))
        CHARSET[] = charset
    end
    menus !== nothing && (INTERACTIVE_MENUS[] = menus)
    return (theme = _current_theme[], highlight = _syntax_highlighting[],
            context_lines = NUM_SOURCE_LINES_UP_DOWN[], vartypes = VARIABLE_TYPES[],
            max_vars = MAX_VARS_IN_STATUS[], sticky = STICKY[], charset = CHARSET[],
            menus = INTERACTIVE_MENUS[])
end
