# Debugger

*A Julia debugger.*

**Build Status**                                                                                |
|:-----------------------------------------------------------------------------------------------:|
| [![][travis-img]][travis-url]  [![][codecov-img]][codecov-url] |

**Note**: If you are looking for the docs for the Juno IDE debugger, see [this link instead]( https://docs.junolab.org/latest/man/debugging/)

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

## Debugger commands

Below, square brackets denote optional arguments.

All of the following commands work when the prompt is `1|debug>`:

Misc:
- `o`: open the current line in an editor
- `q`: quit the debugger, returning `nothing`
- `C`: toggle compiled mode
- `L`: toggle showing lowered code instead of source code
- `+`/`-`: increase / decrease the number of lines of source code shown

Stepping (basic):
- `n`: step to the next line
- `u [i::Int]`: step until line `i` or the next line past the current line
- `s`: step into the next call
- `so`: step out of the current call
- `sl`: step into the last call on the current line (e.g. steps into `f` if the line is `f(g(h(x)))`).
- `sr`: step until next `return`.
- `c`: continue execution until a breakpoint is hit
- `f [i::Int]`: go to the `i`-th function in the call stack (stepping is only possible in the function at the top of the call stack)
- `up/down [i::Int]` go up or down one or `i` functions in the call stack

Stepping (advanced):
- `nc`: step to the next call
- `se`: step one expression step
- `si`: same as `se` but step into a call if a call is the next expression
- `sg`: step into a generated function

Querying:
- `st`: show the "status" (current function, source code and current expression to run)
- `bt`: show a backtrace
- `fr [i::Int]`: show all variables in the current or `i`th frame

Evaluation:
- `w`
    - `w add expr`: add an expression to the watch list
    - `w`: show all watch expressions evaluated in the current function's context
    - `w rm [i::Int]`: remove all or the `i`:th watch expression

Breakpoints:
- `bp`
    - `bp add`
        - `bp add "file.jl":line [cond]`: add a breakpoint att file `file.jl` on line `line` with condition `cond`
        - `bp add func [:line] [cond]`: add a breakpoint to function `func` at line `line` (defaulting to first line)  with condition `cond`
        - `bp add func(::Float64, Int)[:line] [cond]`: add a breakpoint to methods matching the signature at line `line` (defaulting to first line)  with condition `cond`
        - `bp add func(x, y)[:line] [cond]`: add a breakpoint to the method matching the types of the local variable `x`, `y` etc with condition `cond`
        - `bp add line [cond]` add a breakpoint to `line` of the file of the current function  with condition `cond`
    - `bp` show all breakpoints
    - `bp rm [i::Int]`: remove all or the `i`:th breakpoint
    - `bp toggle [i::Int]`: toggle all or the `i`:th breakpoint
    - `bp disable [i::Int]`: disable all or the `i`:th breakpoint
    - `bp enable [i::Int]`: enable all or the `i`:th breakpoint
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
In abs(x) at float.jl:522
>522  abs(x::Float64) = abs_float(x)

About to run: (abs_float)(2.0)
1|debug> bt
[1] abs(x) at float.jl:522
  | x::Float64 = 2.0
[2] sin(x) at special/trig.jl:30
  | x::Float64 = 2.0
  | T::DataType = Float64
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
In string_index_err(s, i) at strings/string.jl:12
>12  @noinline string_index_err(s::AbstractString, i::Integer) =

About to run: (throw)(StringIndexError("αβ", 2))
1|debug> bt
[1] string_index_err(s, i) at strings/string.jl:12
  | s::String = "αβ"
  | i::Int64 = 2
[2] getindex_continued(s, i, u) at strings/string.jl:218
  | s::String = "αβ"
  | i::Int64 = 2
  | u::UInt32 = 0xb1000000
  | val::Bool = false
[3] getindex(s, i) at strings/string.jl:211
  | s::String = "αβ"
  | i::Int64 = 2
  | b::UInt8 = 0xb1
  | u::UInt32 = 0xb1000000
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
In f(x) at REPL[6]:2
 1  function f(x)
 2      if x < 0
>3          @bp
 4      else
 5          println("All good!")
 6      end
 7  end

About to run: return
1|debug> bt
[1] f(x) at REPL[6]:3
  | x::Int64 = -2
```

### Compiled mode

In order to fully support breakpoints, the debugger interprets all code, even code that is stepped over.
Currently, there are cases where the interpreter is too slow for this to be feasible.
A workaround is to use "compiled mode" which is toggled by pressing `C` in the debug REPL mode (note the change of prompt color).
When using compiled mode, code that is stepped over will be executed
by the normal julia compiler and run just as fast as normally.
The drawback is of course that breakpoints in code that is stepped over are missed.


### Syntax highlighting

The source code preview is syntax highlighted and this highlighting has some options.
The theme can be set by calling `Debugger.set_theme(theme)` where `theme` is a [Highlights.jl theme](https://juliadocs.github.io/Highlights.jl/stable/demo/themes/).
It can be completely turned off or alternatively, different quality settings for the colors might be chosen by calling `Debugger.set_highlight(opt)` where `opt` is a `Debugger.HighlightOption` enum.
The choices are `HIGHLIGHT_OFF` `HIGHLIGHT_SYSTEM_COLORS`, `HIGHLIGHT_256_COLORS`, `HIGHLIGHT_24_BIT`. System colors works in pretty much all terminals, 256 in most terminals (with the exception of Windows)
and 24 bit in some terminals.


[travis-img]: https://travis-ci.org/JuliaDebug/Debugger.jl.svg?branch=master
[travis-url]: https://travis-ci.org/JuliaDebug/Debugger.jl

[codecov-img]: https://codecov.io/gh/JuliaDebug/Debugger.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaDebug/Debugger.jl
