# Debugger

*A Julia debugger.*

**Build Status**                                                                                |
|:-----------------------------------------------------------------------------------------------:|
| [![][travis-img]][travis-url]  [![][codecov-img]][codecov-url] |

## Installation

```jl
]add Debugger
```

## Usage

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
out of functions, line stepping, showing local variables, and evaluating code in
the context of functions.

Basic Commands:
- `st`: show the status
- `n`: step to the next line
- `u [i::Int]`: step until line `i` or the next line past the current line
- `s`: step into the next call
- `so`: step out of the current call
- `c`: continue execution until a breakpoint is hit
- `bt`: show a simple backtrace
- ``` `stuff ```: run `stuff` in the current function's context
- `fr [i::Int]`: show all variables in the current or `i`th frame
- `f [i::Int]`: go to the `i`-th function in the call stack
- `up/down [i::Int]` go up or down one or `i` functions in the call stack
- `w`
    - `w add expr`: add an expression to the watch list
    - `w`: show all watch expressions evaluated in the current function's context
    - `w rm [i::Int]`: remove all or the `i`:th watch expression
- `o`: open the current line in an editor
- `q`: quit the debugger, returning `nothing`
- `C`: toggle compiled mode
- `L`: toggle showing lowered code instead of source code
- `+`/`-`: increase / decrease the number of lines of source code shown

Advanced commands:
- `nc`: step to the next call
- `se`: step one expression step
- `si`: same as `se` but step into a call if a call is the next expression
- `sg`: step into a generated function

An empty command will execute the previous command.

### Breakpoints

There are currently no designated commands in the debug mode for adding and removing breakpoints, instead they are manipulated using the API from the package JuliaInterpreter (which is reexported from Debugger). The different ways of manipulating breakpoints are documented [here](https://juliadebug.github.io/JuliaInterpreter.jl/latest/dev_reference/#Breakpoints-1).

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

### Compiled mode

In order to fully support breakpoints, the debugger interprets all code, even code that is stepped over.
Currently, there are cases where the interpreter is too slow for this to be feasible.
A workaround is to use "compiled mode" which is toggled by pressing `C` in the debug REPL mode (note the change of prompt color).
When using compiled mode, code that is stepped over will be executed
by the normal julia compiler and run just as fast as normally.
The drawback is of course that breakpoints in code that is stepped over are missed.


### Syntax highlighting

The source code preview is syntax highlighted and this highlighting has some options.
The theme can be set by calling `Debugger.set_theme(theme)` where `theme` is a [Highlights.jl theme](https://juliadocs.github.io/Highlights.jl/stable/demo/themes.html).
It can be completely turned off or alternatively, different quality settings for the colors might be chosen by calling `Debugger.set_highlight(opt)` where `opt` is a `Debugger.HighlightOption` enum.
The choices are `HIGHLIGHT_OFF` `HIGHLIGHT_SYSTEM_COLORS`, `HIGHLIGHT_256_COLORS`, `HIGHLIGHT_24_BIT`. System colors works in pretty much all terminals, 256 in most terminals (with the exception of Windows)
and 24 bit in some terminals.


[travis-img]: https://travis-ci.org/JuliaDebug/Debugger.jl.svg?branch=master
[travis-url]: https://travis-ci.org/JuliaDebug/Debugger.jl

[codecov-img]: https://codecov.io/gh/JuliaDebug/Debugger.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaDebug/Debugger.jl
