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
    Debugger.@bp
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
    Debugger.@bp
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

function outer(a, b, c, d)
    inner_kw(a, b; c = c)
end

function inner_kw(a, b; c = 3, d = 10)
    return a + b + c + d
end




function f_end(x)
    x = 3 + 3
    return sin(x)
end
"we don't want to see this in the source code printing"


@testset "UI" begin
    if Sys.isunix() && VERSION >= v"1.1.0"
        Debugger._print_full_path[] = false
        using TerminalRegressionTests

        function run_terminal_test(frame, commands, validation)
            TerminalRegressionTests.automated_test(joinpath(@__DIR__, validation), commands) do emuterm
            #TerminalRegressionTests.create_automated_test(joinpath(@__DIR__, validation), commands) do emuterm                
                repl = REPL.LineEditREPL(emuterm, true)
                repl.interface = REPL.setup_interface(repl)
                repl.specialdisplay = REPL.REPLDisplay(repl)
                RunDebugger(frame, repl, emuterm)
            end
        end

        CTRL_C = "\x3"
        EOT = "\x4"
        UP_ARROW = "\e[A"

        run_terminal_test(@make_frame(my_gcd(10, 20)),
                          ["n\n","`", "my_gc\t\n", "a\n", UP_ARROW, UP_ARROW, UP_ARROW, CTRL_C, 
                           "w add a\n", "w add sin(a)\n", "w add b\n", "w\n", "w rm 1\n", "w\n",
                           "s\n", "fr 1\n", "fr 2\n", "f 2\n", "f 1\n",
                           "bt\n", "st\n", "C", "c\n", "C", "c\n"],
                          "ui/history_gcd.multiout")

        run_terminal_test(@make_frame(outer(1, 2, 5, 20)),
                          ["s\n", "c\n"],
                          "ui/history_kw.multiout")

        run_terminal_test(@make_frame(f_end(2)),
                          ["n\n", "n\n", "n\n"],
                          "ui/history_floor.multiout")
        
        if v"1.1">= VERSION < v"1.2"
            run_terminal_test(@make_frame(my_gcd_noinfo(10, 20)),
                            ["n\n","`", "a\n", UP_ARROW, UP_ARROW, CTRL_C, EOT],
                             "ui/history_noinfo.multiout")
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
    state = dummy_state(frame)
    prov = Debugger.DebugCompletionProvider(state)

    c, r = test_complete(prov, "local")
    @test "local_var" in c
end
