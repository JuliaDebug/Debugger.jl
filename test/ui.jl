#
#
# From base, but copied here to make sure we don't fail bacause base changed
function my_gcd(a::T, b::T) where T<:Union{Int8,UInt8,Int16,UInt16,Int32,UInt32,Int64,UInt64,Int128,UInt128}
    a == 0 && return abs(b)
    b == 0 && return abs(a)
    za = trailing_zeros(a)
    zb = trailing_zeros(b)
    k = min(za, zb)
    u = unsigned(abs(a >> za))
    v = unsigned(abs(b >> zb))
    while u != v
        if u > v
            u, v = v, u
        end
        v -= u
        v >>= trailing_zeros(v)
    end
    r = u << k
    # T(r) would throw InexactError; we want OverflowError instead
    r > typemax(T) && throw(OverflowError("gcd($a, $b) overflows"))
    r % T
end

# make sure source code is unavailable for this method:
include_string(@__MODULE__, """
function my_gcd_noinfo(a::T, b::T) where T<:Union{Int8,UInt8,Int16,UInt16,Int32,UInt32,Int64,UInt64,Int128,UInt128}
    a == 0 && return abs(b)
    b == 0 && return abs(a)
    za = trailing_zeros(a)
    zb = trailing_zeros(b)
    k = min(za, zb)
    u = unsigned(abs(a >> za))
    v = unsigned(abs(b >> zb))
    while u != v
        if u > v
            u, v = v, u
        end
        v -= u
        v >>= trailing_zeros(v)
    end
    r = u << k
    # T(r) would throw InexactError; we want OverflowError instead
    r > typemax(T) && throw(OverflowError("gcd(\$a, \$b) overflows"))
    r % T
end
""", "nope.jl")

@testset "UI" begin
    if Sys.isunix() && VERSION >= v"1.1.0"
        using TerminalRegressionTests

        thisdir = @__DIR__
        TerminalRegressionTests.automated_test(
                        joinpath(thisdir,"ui/history_gcd.multiout"),
                    ["n\n","`", "a\n", "\e[A", "\e[A", "\x3", "\x4"]) do emuterm
            repl = REPL.LineEditREPL(emuterm, true)
            repl.interface = REPL.setup_interface(repl)
            repl.specialdisplay = REPL.REPLDisplay(repl)
            stack = JuliaInterpreter.@make_stack my_gcd(10, 20)
            stack[1] = JuliaInterpreter.JuliaStackFrame(stack[1], stack[1].pc[]; fullpath=false)
            RunDebugger(stack, repl, emuterm)
        end
        if VERSION == v"1.1.0"
            TerminalRegressionTests.automated_test(
                            joinpath(thisdir,"ui/history_noinfo.multiout"),
                        ["n\n","`", "a\n", "\e[A", "\e[A", "\x3", "\x4"]) do emuterm
                repl = REPL.LineEditREPL(emuterm, true)
                repl.interface = REPL.setup_interface(repl)
                repl.specialdisplay = REPL.REPLDisplay(repl)
                stack = JuliaInterpreter.@make_stack my_gcd_noinfo(10, 20)
                stack[1] = JuliaInterpreter.JuliaStackFrame(stack[1], stack[1].pc[]; fullpath=false)
                RunDebugger(stack, repl, emuterm)
            end
        else
            @warn "Skipping tests for IR display due to mismatched Julia versions."
        end
    else
        @warn "Skipping UI tests on non unix systems"
    end
end

# Completions
function test_complete(c, s)
    c, r, s = Debugger.completions(c, s, lastindex(s))
    return unique!(map(REPL.REPLCompletions.completion_text, c)), r, s
end

module F
    local_var = 1
    f(x) = x
end

@testset "REPL completions" begin
    frame = JuliaInterpreter.enter_call_expr(:($(F.f)(1)))
    state = dummy_state([frame])
    prov = Debugger.DebugCompletionProvider(state)

    c, r = test_complete(prov, "local")
    @test "local_var" in c
end
