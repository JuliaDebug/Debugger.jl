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
- `n`: step to the next line
- `s`: step into the next call
- `so`: step out of the current call
- `bt`: show a simple backtrace
- ``` `stuff ```: run `stuff` in the current function's context
- `fr [v::Int]`: show all variables in the current function, `v` defaults to `1`
- `f [n::Int]`: go to the `n`-th function in the call stack
- `q`: quit the debugger, returning `nothing`
Advanced commands:
- `nc`: step to the next call
- `se`: step one expression step
- `si`: same as `se` but step into a call if a call is the next expression
- `sg`: step into a generated function


[travis-img]: https://travis-ci.org/JuliaDebug/Debugger.jl.svg?branch=master
[travis-url]: https://travis-ci.org/JuliaDebug/Debugger.jl

[codecov-img]: https://codecov.io/gh/JuliaDebug/Debugger.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaDebug/Debugger.jl
