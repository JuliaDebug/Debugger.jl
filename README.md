# Debugger

*A Julia debugger.*

**Build Status**                                                                                |
|:-----------------------------------------------------------------------------------------------:|
| [![][travis-img]][travis-url]  [![][codecov-img]][codecov-url] |

## Installation

```jl
]add https://github.com/JuliaDebug/JuliaInterpreter.jl
]add https://github.com/JuliaDebug/Debugger.jl
```

## Usage

```julia
using Debugger

function foo(n)
    x = n+1
    ((BigInt[1 1; 1 0])^x)[2,1]
end

@enter foo(20)
```

Basic Commands:
- `n` steps to the next line
- `s` steps into the next call
- `finish` runs to the end of the function
- `bt` shows a simple backtrace
- ``` `stuff ``` runs `stuff` in the current frame's context
- `fr v` will show all variables in the current frame
- `f n` where `n` is an integer, will go to the `n`-th frame
- `q` quits the debugger, returning `nothing`

Advanced commands:
- `nc` steps to the next call
- `ns` steps to the next statement
- `se` does one expression step
- `si` does the same but steps into a call if a call is the next expression
- `sg` steps into a generated function

## Breakpoints

There are currently no designated commands in the debug mode for adding and removing breakpoints, instead they are manipulated using the API from the package JuliaInterpreter (which need to be installed). The different ways of manipulating breakpoints are documented [here](https://juliadebug.github.io/JuliaInterpreter.jl/latest/dev_reference/#Breakpoints-1).

It is common to want to run a function until a breakpoint is hit. Therefore, the "shortcut macro" `@run` is provided which is equivalent
of starting the debug mode with `@enter` and then executing the continue command (`c`):

```jl
julia> using Debugger, JuliaInterpreter

julia> breakpoint(abs);

julia> @run sin(2.0)
Hit breakpoint: abs(x::Float64) in Base at float.jl:522, line 522
In abs(x) at float.jl:522
522   abs(x::Float64) = abs_float(x)
523   
524   """

About to run: (abs_float)(2.0)
1|debug> bt
[1] abs(x) at float.jl:522
  | x::Float64 = 2.0
[2] sin(x) at special/trig.jl:30
  | x::Float64 = 2.0
  | T::DataType = Float64
```

### Breakpoint on error

It is possible to halt execution when an error is thrown. This is done by calling the exported function `break_on_error(true)`.

```jl
julia> using Debugger

julia> break_on_error(true)

julia> f() = "αβ"[2];

> @run f()
Breaking on error: string_index_err(s::AbstractString, i::Integer) in Base at strings/string.jl:12, line 12, StringIndexError("αβ", 2)
In string_index_err(s, i) at strings/string.jl:12
12  @noinline string_index_err(s::AbstractString, i::Integer) =
13      throw(StringIndexError(s, Int(i)))
14  

About to run: (throw)(StringIndexError("αβ", 2))
1|debug> bt
[1] string_index_err(s, i) at strings/string.jl:12
  | s::String = "αβ"
  | i::Int64 = 2
[2] getindex_continued(s, i, u) at strings/string.jl:215
  | s::String = "αβ"
  | i::Int64 = 2
  | u::UInt32 = 0xb1000000
  | val::Bool = false
[3] getindex(s, i) at strings/string.jl:208
  | s::String = "αβ"
  | i::Int64 = 2
  | b::UInt8 = 0xb1
  | u::UInt32 = 0xb1000000
[4] f() at REPL[17]:1
```

[travis-img]: https://travis-ci.org/JuliaDebug/Debugger.jl.svg?branch=master
[travis-url]: https://travis-ci.org/JuliaDebug/Debugger.jl

[codecov-img]: https://codecov.io/gh/JuliaDebug/Debugger.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaDebug/Debugger.jl
