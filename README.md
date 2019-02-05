# Debugger

*A Julia debugger.*

**Build Status**                                                                                |
|:-----------------------------------------------------------------------------------------------:|
| [![][travis-img]][travis-url]  [![][codecov-img]][codecov-url] |

## Installation

```jl
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
- `f n` where `n` is an integer, will go to the `n`-th frame.

Advanced commands:
- `nc` steps to the next call
- `ns` steps to the next statement
- `se` does one expression step
- `si` does the same but steps into a call if a call is the next expression
- `sg` steps into a generated function
- `loc` shows the column data for the current top frame, in the same format
  as JuliaParsers's testshell.


[travis-img]: https://travis-ci.org/juliadebug/Debugger.jl.svg?branch=master
[travis-url]: https://travis-ci.org/juliadebug/Debugger.jl

[codecov-img]: https://codecov.io/gh/juliadebug/Debugger.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/juliadebug/Debugger.jl
