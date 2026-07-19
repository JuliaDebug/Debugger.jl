# Debugger.jl changelog

## Version 0.9.0 (unreleased)

This release adds mixed-mode stepping (the new default) and overhauls the
terminal UI. The most visible changes: stepping over Base/dependency code runs
at native speed, the debugger runs full screen by default, `bp`/`f`/`w`/`focus`
open interactive menus, and a new `debug>` REPL mode is entered with `)`.

### Mixed-mode stepping — the new default

Instead of interpreting everything (slow) or stepping over compiled code
blindly (breakpoints missed), the debugger now interprets only calls that can
reach the "focus set" — `Main`, packages loaded from dev checkouts, the package
you `@enter`ed, and anything you add — and runs everything else natively.
Callbacks and user types passed into Base or dependency code keep the carrying
call chain interpreted, so `map(f, xs)`, `sort(xs; by = f)`, broadcasts and
do-blocks remain fully debuggable while e.g. `sort(::Vector{Int})` runs at
compiled speed. Breakpoints anywhere outside the focus set automatically fall
back to full interpretation, with a message.

- The prompt shows the mode: `1|debug>` (mixed, the default),
  `1|interpreted>`, `1|compiled>` — each with its own color.
- `M` toggles mixed ↔ interpreted; `C` still toggles compiled mode.
- `mode [interpreted|mixed|compiled]` shows/sets the mode;
  `Debugger.set_default_mode!(:interpreted)` (e.g. in `startup.jl`) restores
  the previous default.
- `focus` shows and manages the focus set; stepping into a dependency package
  adds it to the set for the session (a message is printed).
- API: `Debugger.interpret_module!`, `Debugger.compile_module!`,
  `Debugger.reset_module!`, `Debugger.interpreted_modules`.

### Keys at the `debug>` prompt

Pressed at the beginning of an empty prompt line:

| Key | Action |
|:----|:-------|
| `` ` `` | enter evaluation mode (as before) |
| `C` | toggle compiled mode (as before) |
| `M` | **new** — toggle mixed mode |
| `L` | toggle lowered code (as before) |
| `T` | **new** — cycle how variable types are shown: compact → none → types only → full |
| `S` | **new** — toggle "sticky" (full-screen) mode |
| `+`/`-` | more/fewer source lines (as before) |

### Full-screen ("sticky") mode — on by default

The debugger session now runs on the terminal's alternate screen, like `less`
or `vim`: your scrollback is untouched and the terminal is restored exactly
when you quit. The status is redrawn in place on every step instead of
scrolling. Press `S` or set `Debugger.config(sticky = false)` to get the old
scrolling transcript back.

### Interactive menus

- `bp` (no arguments) opens a breakpoint manager: move with the arrow keys,
  **space/enter** toggles a breakpoint, **`a`** adds one (prompts for a
  location using the `bp add` syntax), **`d`** deletes it, **`o`** opens its
  location in your editor, **`q`** quits. Break-on-error and break-on-throw
  are toggleable rows in the same menu.
- `f` (no arguments) opens a frame picker for the call stack.
- `w` (no arguments) opens the watch list (**`d`** deletes an entry).
- `focus` (no arguments) opens the mixed-mode focus set: **space/enter**
  toggles whether a module is interpreted, **`a`** adds one by name.

All existing subcommands (`bp rm 2`, `bp add foo:12`, `f 3`, `w rm 1`, ...)
still work, and non-interactive terminals automatically get the old text
output. `Debugger.config(menus = false)` disables the menus.

### The `debug>` REPL mode

Loading Debugger installs a REPL mode entered by pressing `)` at the beginning
of an empty `julia>` prompt (backspace leaves it, like the Pkg mode):

- any expression you enter is debugged as if run through `@enter`
- `bp` commands (including the menu) work there *without* an active debug
  session, so breakpoints can be set up before debugging

### Status display

- header shows the position in the call stack: `[1/4] foo(x, y) at foo.jl:12`
- the current source line is shown in bold
- local variables are shown as part of the status: arguments first (tagged
  `(arg)`, `(param)`, `(captured)`), aligned, truncated to the terminal width
- variable types display compactly by default — long parametric types elide to
  `Dict{…}`; cycle with `T` or set `Debugger.config(vartypes = ...)` (#396)
- watch expressions are evaluated and shown in the status on every step
- the next expression is marked with `→` instead of `About to run:`
- keyword methods display as `f(x, y; z)` instead of the mangled `#f#5(z, , x, y)`

### Commands

- `bt` is now a compact one-line-per-frame backtrace with a marker on the
  active frame; `bt v` gives the old verbose listing including all variables
- `p x` shows the full value the way the REPL would display it, instead of a
  truncated single line

### Configuration

All UI options live in one place; call without arguments to see the current
settings:

```julia
Debugger.config(; theme, highlight, context_lines, vartypes, max_vars,
                  sticky, charset, menus)
```

`charset = :ascii` replaces all unicode markers. `Debugger.set_theme` and
`Debugger.set_highlight` still work.

### Fixes and performance

- stepping no longer lags: syntax highlighting cached the wrong way around a
  tree-sitter bottleneck (~230 ms per status print → ~1 ms;
  JuliaDocs/Highlights.jl#90)
- first use compiles far less at runtime thanks to a precompile workload
  (~5 s → ~0.25 s)
- errors from code evaluated at the `|julia>` prompt no longer print a dozen
  frames of debugger internals below the error
- when the debugger pauses on a global load (Julia 1.12), the upcoming call is
  previewed even when the global is an argument (`→ map(*, x, y)` instead of
  `→ Base.Math.:*`)
