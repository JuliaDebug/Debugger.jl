#
#
# From base, but copied here to make sure we don't fail because base changed
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

g_invoke(a, b, c, d, e) = a + b + c + d + e
function f_invoke(x, y, z)
    return g_invoke(x..., y, z...)
end

function f_until(x)
    s = 1 + 1
    s = 2 + 2
    s = 3 + 3
    for v in x
        s += v
    end
    return s
end

function f_up_down_1(x, y)
    f_up_down_2(x, y)
end
function f_up_down_2(x, y)
    f_up_down_3(x, y)
end
function f_up_down_3(x, y)
    return x + y
end


function mysum(x)
    s = 0
    for v in x
        s += v
    end
    return s
end


@testset "UI" begin
    if Sys.isunix() && get(ENV, "DEBUGGER_RUN_UI_TESTS", "false") == "true"
        print_full_path = Debugger._print_full_path[]
        source_lines = Debugger.NUM_SOURCE_LINES_UP_DOWN[]
        watch_list = copy(Debugger.WATCH_LIST)
        Debugger._print_full_path[] = false
        try
            using TerminalRegressionTests

            function normalize_terminal_output(output)
                output = replace(output,
                    r"(?m)^[ >]*\d+(?=\s)" => m -> replace(m, r"\d" => '#'),
                    r"(?<=:)\d+(?=\b)" => m -> replace(m, r"\d" => '#'),
                    r"#\d+" => "#<id>")
                return output
            end

            # `A` is the default VT100 cell decoration. Normalizing generated-function
            # identifiers can change a line's width, so trailing default cells are not
            # meaningful even though every non-default decoration remains strict.
            normalize_terminal_decorator(decorator) =
                replace(decorator, r"A+$"m => "")

            function compare_terminal_output(emulator, output, decorator=nothing)
                output_buffer = IOBuffer()
                decorator_buffer = IOBuffer()
                TerminalRegressionTests.VT100.dump(output_buffer, decorator_buffer, emulator)
                expected_output = normalize_terminal_output(output)
                actual_output = normalize_terminal_output(String(take!(output_buffer)))
                TerminalRegressionTests._compare(
                    Vector{UInt8}(codeunits(expected_output)),
                    Vector{UInt8}(codeunits(actual_output)))
                decorator === nothing && return true
                expected_decorator = normalize_terminal_decorator(decorator)
                actual_decorator = normalize_terminal_decorator(String(take!(decorator_buffer)))
                return TerminalRegressionTests._compare(
                    Vector{UInt8}(codeunits(expected_decorator)),
                    Vector{UInt8}(codeunits(actual_decorator)))
            end

            function run_terminal_test(frame, commands, validation)
                run_debugger = function (emuterm)
                    repl = REPL.LineEditREPL(emuterm, true)
                    repl.interface = REPL.setup_interface(repl)
                    repl.specialdisplay = REPL.REPLDisplay(repl)
                    RunDebugger(frame, repl, emuterm)
                end
                output_path = joinpath(@__DIR__, validation)
                if get(ENV, "DEBUGGER_UPDATE_UI_SNAPSHOTS", "false") == "true"
                    TerminalRegressionTests.create_automated_test(run_debugger, output_path, commands)
                else
                    TerminalRegressionTests.automated_test(
                        run_debugger, compare_terminal_output, output_path, commands)
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

            run_terminal_test(@make_frame(f_invoke((1,2), 3, [4,5])),
                              ["nc\n", "s\n", "c\n"],
                              "ui/history_apply.multiout")

            run_terminal_test(@make_frame(f_until([1,2,3,4,5,6,7,8])),
                              ["+", "-", "u 76\n", "u\n", "u\n", "u\n", "c\n"],
                              "ui/history_until.multiout")

            run_terminal_test(@make_frame(f_up_down_1(5, 3)),
                              ["s\n", "s\n", "up\n", "down\n", "up 2\n", "down 2\n", "c\n"],
                              "ui/history_updown.multiout")

            run_terminal_test(@make_frame(mysum([1,2,3,4,5])),
                              ["bp add mysum:97 v > 3\n", "c\n", "bp rm\n", "c\n"],
                              "ui/bp_ui.multiout")

            run_terminal_test(@make_frame(mysum(collect(1:10000))),
                              ["bt\n", "c\n"],
                              "ui/big_repr_ui.multiout")

            was_breaking_on_error = JuliaInterpreter.break_on_error[]
            Debugger.break_on(:error)
            try
                run_terminal_test(@make_frame(error("foo")),
                                  ["c\n", "bt\n", "q\n"],
                                  "ui/history_break_error.multiout")
            finally
                if was_breaking_on_error
                    Debugger.break_on(:error)
                else
                    Debugger.break_off(:error)
                end
            end

            run_terminal_test(@make_frame(my_gcd_noinfo(10, 20)),
                              ["n\n","`", "a\n", UP_ARROW, UP_ARROW, CTRL_C, EOT],
                              "ui/history_noinfo.multiout")
        finally
            Debugger._print_full_path[] = print_full_path
            Debugger.NUM_SOURCE_LINES_UP_DOWN[] = source_lines
            empty!(Debugger.WATCH_LIST)
            append!(Debugger.WATCH_LIST, watch_list)
        end
    else
        @warn "Skipping UI tests"
    end
end

# Completions
test_complete(c, s) = Debugger.completions(c, s, s)

module F
    local_var = 1
    f(f_args) = f_args
end

@testset "REPL completions" begin
    frame = JuliaInterpreter.enter_call_expr(:($(F.f)(1)))
    state = dummy_state(frame)
    prov = Debugger.DebugCompletionProvider(state)

    c, _ = test_complete(prov, "local")
    @test "local_var" in c
    c, _ = test_complete(prov, "f_")
    @test "f_args" in c
end
