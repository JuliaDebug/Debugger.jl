# Debugger

*A Julia debugger.*

**Build Status**                                                                                |
|:-----------------------------------------------------------------------------------------------:|
| [![][travis-img]][travis-url]  [![][codecov-img]][codecov-url] |

**Note**: If you are looking for the docs for the Julia VSCode debugger, see [this link instead](https://www.julia-vscode.org/docs/stable/userguide/debugging/)

## Installation

Install Debugger using [Pkg](https://docs.julialang.org/en/v1/stdlib/Pkg/):

```julia
julia> import Pkg; Pkg.add("Debugger")
```

# Usage

## Starting the debugger interface

The debug interface is entered using the `@enter` macro:

```julia
using Debugger

function foo(n)
    x = n+1
    ((BigInt[1 1; 1 0])^x)[2,1]
end

@enter foo(20)
```

This interface allows for manipulating program execution, such as stepping in and
out of functions, line stepping, showing local variables, setting breakpoints and evaluating code in
the context of functions.

## The `debug>` REPL mode

Loading Debugger in an interactive session installs a `debug>` REPL mode, entered
by pressing `)` at the beginning of an empty `julia>` prompt (and left with backspace,
like the Pkg and shell modes). In this mode:

- any expression you enter is debugged as if run through `@enter`,
- breakpoints can be managed with the usual `bp` commands (see below) — also
  *outside* of a debug session; breakpoints persist between sessions.

```
julia> using Debugger

debug> bp add sin
[ Info: added breakpoint for function sin

debug> cos(1.0)  # equivalent to @enter cos(1.0)
```

## Debugger commands

Below, square brackets denote optional arguments.

All of the following commands work when the prompt is `1|debug>`:

Misc:
- `o`: open the current line in an editor
- `q`: quit the debugger, returning `nothing`
- `C`: toggle compiled mode
- `M`: toggle mixed mode (see "Stepping modes" below)
- `mode [interpreted|mixed|compiled]`: show or set the stepping mode
- `L`: toggle showing lowered code instead of source code
- `T`: cycle how variable types are shown: compact (long type parameters elided), no types, types only, full types
- `S`: toggle "sticky" (full-screen) mode, on by default: the debugger runs on the terminal's alternate screen (restored when quitting, like `less` or `vim`) and redraws the status in place instead of scrolling; command output taller than the screen (e.g. the `?` help) is shown in a scrollable pager
- `+`/`-`: increase / decrease the number of lines of source code shown

Stepping (basic):
- `n`: step to the next line
- `u [i::Int]`: step until line `i` or the next line past the current line
- `s`: step into the next call
- `so`: step out of the current call
- `sl`: step into the last call on the current line (e.g. steps into `f` if the line is `f(g(h(x)))`).
- `sr`: step until next `return`.
- `c`: continue execution until a breakpoint is hit
- `f [i::Int]`: go to the `i`-th function in the call stack; without an argument, pick the frame interactively (stepping is only possible in the function at the top of the call stack)
- `up/down [i::Int]` go up or down one or `i` functions in the call stack

Stepping (advanced):
- `nc`: step to the next call
- `se`: step one expression step
- `si`: same as `se` but step into a call if a call is the next expression
- `sg`: step into a generated function

Querying:
- `st`: show the "status" (current function, source code and current expression to run)
- `bt [v]`: show a compact backtrace; `bt v` also shows the variables of every frame
- `fr [i::Int]`: show all variables in the current or `i`th frame
- `p`
    - `p`: print all variables in the current frame (same as `fr`)
    - `p x [y ...]`: print the full value of the variable(s) `x` (and `y` ...), like the REPL would show it

Evaluation:
- `w`
    - `w add expr`: add an expression to the watch list; watch expressions are evaluated and shown as part of the status
    - `w`: interactively manage the watch list (delete entries with `d`)
    - `w rm [i::Int]`: remove all or the `i`-th watch expression

Breakpoints:
- `bp`
    - `bp`: interactively manage breakpoints — move with the arrow keys, toggle with space/enter,
      add with `a` (prompts for a location using the `bp add` syntax below), delete with `d`,
      open the breakpoint location in an editor with `o`, quit with `q`.
      Break-on-error and break-on-throw can be toggled from the same menu.
    - `bp add`
        - `bp add "file.jl":line [cond]`: add a breakpoint at file `file.jl` on line `line` with condition `cond`
        - `bp add func [:line] [cond]`: add a breakpoint to function `func` at line `line` (defaulting to first line) with condition `cond`
        - `bp add func(::Float64, Int)[:line] [cond]`: add a breakpoint to methods matching the signature at line `line` (defaulting to first line) with condition `cond`
        - `bp add func(x, y)[:line] [cond]`: add a breakpoint to the method matching the types of the local variable `x`, `y` etc with condition `cond`
        - `bp add line [cond]`: add a breakpoint to `line` of the file of the current function with condition `cond`
    - `bp rm [i::Int]`: remove all or the `i`-th breakpoint
    - `bp rm "file.jl":line`: remove the breakpoint at the given file and line
    - `bp rm func [:line]`: remove breakpoints for the function `func` (at line `line`)
    - `bp toggle [i::Int]`: toggle all or the `i`-th breakpoint
    - `bp disable [i::Int]`: disable all or the `i`-th breakpoint
    - `bp enable [i::Int]`: enable all or the `i`-th breakpoint
    - `bp on/off`
      - `bp on/off error` - turn on or off break on error
      - `bp on/off throw` - turn on or off break on throw

An empty command will execute the previous command.

Changing frames with `f i::Int` will change the prompt to `$i|debug>`.
Stepping commands will not work until you return to `f 1`, but a subset of normal commands will continue to work.

In addition to these debugging commands, you can type `` ` `` to enter "evaluation mode" indicated by a prompt `$i|julia>`.
In evaluation mode, any expression you type is executed in the debug context.
For example, if you have a local variable named `n`, then once in evaluation mode typing `n` will show you the value of `n` rather than advancing to the next line.

Hit backspace as the first character of the line to return to "debug mode."

### Breakpoints

To add and manipulate breakpoints, either the `bp add` command in the debug interface or the JuliaInterpreter breakpoint API, documented [here](https://juliadebug.github.io/JuliaInterpreter.jl/latest/dev_reference/#Breakpoints-1)
can be used.

It is common to want to run a function until a breakpoint is hit. Therefore, the "shortcut macro" `@run` is provided which is equivalent
of starting the debug mode with `@enter` and then executing the continue command (`c`):

```jl
julia> using Debugger

julia> breakpoint(abs);

julia> @run sin(2.0)
Hit breakpoint:
[1/2] abs(x) at float.jl:522
>522  abs(x::Float64) = abs_float(x)

  x::Float64 = 2.0  (arg)

→ (abs_float)(2.0)
1|debug> bt
>[1] abs(x) at float.jl:522
 [2] sin(x) at special/trig.jl:30
```

#### Breakpoint on error

It is possible to halt execution when an error is thrown. This is done by calling the exported function `break_on(:error)`.

```jl
julia> using Debugger

julia> break_on(:error)

julia> f() = "αβ"[2];

julia> @run f()
Breaking for error:
ERROR: StringIndexError("αβ", 2)
[1/4] string_index_err(s, i) at strings/string.jl:12
>12  @noinline string_index_err(s::AbstractString, i::Integer) =

  s::String = "αβ"  (arg)
  i::Int64  = 2     (arg)

→ (throw)(StringIndexError("αβ", 2))
1|debug> bt
>[1] string_index_err(s, i) at strings/string.jl:12
 [2] getindex_continued(s, i, u) at strings/string.jl:218
 [3] getindex(s, i) at strings/string.jl:211
 [4] f() at REPL[5]:1

julia> JuliaInterpreter.break_off(:error)

julia> @run f()
ERROR: StringIndexError("αβ", 2)
Stacktrace:
[...]
```

### Place breakpoints in source code
It is sometimes more convenient to choose in the source code when to break. This is done for instance in Matlab/Octave with `keyboard`, and in R with `browser()`. You can use the `@bp` macro to do this:

```jl
julia> using Debugger

julia> function f(x)
           if x < 0
               @bp
           else
               println("All good!")
           end
       end
f (generic function with 1 method)

julia> @run f(2)
All good!

julia> @run f(-2)
Hit breakpoint:
[1/1] f(x) at REPL[6]:2
 1  function f(x)
 2      if x < 0
>3          @bp
 4      else
 5          println("All good!")
 6      end
 7  end

  x::Int64 = -2  (arg)

→ return
1|debug> bt
>[1] f(x) at REPL[6]:3
```

### Stepping modes: interpreted, mixed and compiled

In order to fully support breakpoints, the debugger can interpret all code, even code that is stepped
over. Currently, there are cases where the interpreter is too slow for this to be feasible. The
debugger therefore supports three stepping modes:

- **mixed** (the default): calls into modules outside the "focus set" — `Core`, `Base`, the standard
  libraries *and* dependency packages — run natively, at full compiled speed, *unless* the call could
  reach focus code. A call is interpreted whenever the callee or any argument carries a function or
  type from a focus module, also inside wrappers: `map(f, xs)`, `sort(xs; by = f)`, `f.(xs)`,
  do-blocks, `Vector{MyType}` arguments and so on all remain fully debuggable, while e.g.
  `sort(::Vector{Int})` or a `DataFrames` call operating purely on its own types runs at native
  speed. As the default, it keeps the plain `1|debug>` prompt.
- **interpreted**: everything is interpreted; breakpoints always work, including the corner cases
  mixed mode cannot catch (see below). Toggled with the `M` key (note the `1|interpreted>` prompt
  and its color).
- **compiled**: everything that is stepped over runs natively. Fastest, but breakpoints in code that
  is stepped over are missed. Toggled with the `C` key (note the `1|compiled>` prompt and its color).

The mode can also be shown/set with the `mode [interpreted|mixed|compiled]` command in the debug REPL,
and the mode new sessions start in can be set (e.g. in `startup.jl`) with:

```jl
Debugger.set_default_mode!(:interpreted)
```

The focus set — the modules mixed mode interprets — is seeded automatically at each `@enter`/`@run`:

- `Main` (functions defined at the REPL or in scripts);
- every loaded package whose source is a *dev checkout* (a `pkgdir` outside the read-only
  `~/.julia/packages` store), i.e. the packages you are plausibly developing;
- the package of the function you entered (so `@enter DataFrames.groupby(df, :a)` makes `DataFrames`
  debuggable even though it is a registered install) — except `Base`/stdlibs, which would de-facto
  disable the fast path;
- stepping into (`s`) a frame of a dependency package adds it to the focus set for the session (an
  info message is printed). Stepping into `Base`/a stdlib does *not* — a hint is printed instead.

Inside the debugger, `focus` opens an interactive menu over the current set (space/enter toggles a
module, `a` adds one by name); `focus add SomeMod` / `focus rm SomeMod` (or `focus rm i` by number)
do the same non-interactively. These adjust the session; the permanent equivalents, e.g. for
`startup.jl`:

```jl
Debugger.interpret_module!(SparseArrays) # always interpret (debug into) this module
Debugger.compile_module!(MyBigHelperPkg) # never interpret this module (also skips its `@bp` markers)
Debugger.interpreted_modules()           # show the current focus set
```

For soundness, mixed mode automatically falls back to full interpretation while any breakpoint is set
outside the focus set (including file breakpoints that could match such a module), while a breakpoint
is set in a focus package that loaded non-focus packages depend on (native code in the latter could
otherwise run past it), or while `break_on(:error)` or `break_on(:throw)` is active — a message is
printed when this happens. Known limitations of mixed mode (switch to interpreted mode if they
matter): focus-module callbacks hidden in type-erased containers (e.g. `Vector{Any}`, fields typed
`::Function`) are not detected; neither are focus-module methods whose signatures only mention
non-focus types (type piracy), nor focus code reached without any focus-typed argument at the call
site (callbacks stored in global registries, `Task`s, finalizers). `@bp` markers inside non-focus
modules are skipped, and file breakpoints on source that was `eval`'d or `include`d from outside a
package directory may not trigger the fallback.

The [`JuliaInterpreter.compiled_methods`/`compiled_modules`](https://github.com/JuliaDebug/JuliaInterpreter.jl)
mechanisms keep working in every mode and take precedence over mixed mode's decisions
(as does `JuliaInterpreter.interpreted_methods`, in the other direction). For example, to compile all
code in Base even in interpreted mode:

```jl
using JuliaInterpreter, MethodAnalysis
union!(JuliaInterpreter.compiled_modules, child_modules(Base))
```


### Configuration

UI options are set with `Debugger.config(; kwargs...)`; calling it without arguments
shows the current settings. The available options are:

- `theme::String`: syntax highlighting theme, a [Highlights.jl theme](https://highlights.juliadocs.org/dev/themes/) name (default: `"Monokai Dark"`)
- `highlight::Bool`: syntax highlight source code and variables (default: `true`)
- `context_lines::Int`: number of source lines shown above and below the current line (default: `4`)
- `vartypes::Symbol`: how variable types are displayed: `:compact` (long type parameters elided, e.g. `Dict{…}`),
  `:none`, `:types` or `:full` (default: `:compact`); can also be cycled with the `T` key in the debugger
- `max_vars::Int`: maximum number of variables shown in the automatic status display (default: `15`)
- `sticky::Bool`: "full screen" mode — the debugger runs on the terminal's alternate screen and redraws the status in place instead of scrolling (default: `true`); can also be toggled with the `S` key
- `charset::Symbol`: `:unicode` or `:ascii` (default: `:unicode`)
- `menus::Bool`: use the interactive menus for `bp`, `f`, `w` and `focus` (default: `true`)

The older entry points `Debugger.set_theme(theme)` and `Debugger.set_highlight(false)` still work.

[travis-img]: https://travis-ci.org/JuliaDebug/Debugger.jl.svg?branch=master
[travis-url]: https://travis-ci.org/JuliaDebug/Debugger.jl

[codecov-img]: https://codecov.io/gh/JuliaDebug/Debugger.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaDebug/Debugger.jl
