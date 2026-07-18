# Issue #14

using Debugger: _iscall
using JuliaInterpreter
using JuliaInterpreter: pc_expr, evaluate_call!, finish_and_return!, enter_call_expr
runframe(frame::Frame, pc=frame.pc[]) = Some{Any}(finish_and_return!(NonRecursiveInterpreter(), frame))

frame = @make_frame map(x->2x, 1:10)
state = dummy_state(frame)
execute_command(state, Val{:so}(), "so")
@test isnothing(state.frame)
@test state.overall_result == 2 .* [1:10...]

# Issue #12
function complicated_keyword_stuff(args...; kw...)
    args[1] == args[1]
    (args..., kw...)
end
frame = @make_frame complicated_keyword_stuff(1)
state = dummy_state(frame)
execute_command(state, Val{:n}(), "n")
execute_command(state, Val{:so}(), "so")
@test isnothing(state.frame)

@test runframe(JuliaInterpreter.enter_call(complicated_keyword_stuff, 1, 2)) ==
      runframe(@make_frame(complicated_keyword_stuff(1, 2)))
@test runframe(JuliaInterpreter.enter_call(complicated_keyword_stuff, 1, 2; x=7, y=33)) ==
      runframe(@make_frame(complicated_keyword_stuff(1, 2; x=7, y=33)))

# Issue #22
f22() = string(:(a+b))
@test step_through(enter_call_expr(:($f22()))) == "a + b"
f22() = string(QuoteNode(:a))
@test step_through(enter_call_expr(:($f22()))) == ":a"

# Breakpoints
f_outer_break(x) = f_inner_break(x)
f_inner_break(x) = x
JuliaInterpreter.breakpoint(f_inner_break)
frame = @make_frame f_outer_break(2)
state = dummy_state(frame)
execute_command(state, Val{:so}(), "c")
@test state.frame.framecode.scope.name === :f_inner_break
execute_command(state, Val{:so}(), "c")
@test state.frame === nothing
@test state.overall_result == 2

@inline fnothing(x) = 1
frame = @make_frame fnothing(0)
@test chomp(sprint(Debugger.print_next_expr, frame)) == "About to run: return 1"

# Julia 1.12 can initially pause on the global lookup immediately before a call.
frame = @make_frame (20 == 0)
frame.pc = 1
@test chomp(sprint(Debugger.print_next_expr, frame)) == "About to run: (===)(20, 0)"

f_preview_add(x, y) = x + y
frame = @make_frame f_preview_add(6, 4)
frame.pc = 1
@test chomp(sprint(Debugger.print_next_expr, frame)) == "About to run: (+)(6, 4)"

function f()
    x = 1 + 1
    @info "hello"
end
# https://github.com/JuliaDebug/Debugger.jl/issues/71
frame = Debugger.@make_frame f()
state = dummy_state(frame)
execute_command(state, Val{:n}(), "n")
defline, deffile, current_line, body = Debugger.locinfo(state.frame)
@test occursin("handle_message(logger, level", body)

f_unicode() = √

try
    Debugger.set_highlight(true)
    frame = Debugger.@make_frame f()
    st = chomp(sprint(Debugger.print_status, frame; context = :color => true))
    x_1_plus_1_colored = "x\e[0m \e[38;2;249;248;245m=\e[0m \e[38;2;244;191;117m1\e[0m \e[38;2;249;248;245m+\e[0m \e[38;2;244;191;117m"
    @test occursin(x_1_plus_1_colored, st)

    frame = Debugger.@make_frame f_unicode()
    st = chomp(sprint(Debugger.print_status, frame; context = :color => true))
    @test occursin("√", st)
finally
    Debugger.set_highlight(false)
end

frame = @make_frame Test.TestLogger()
desc = Debugger.locdesc(frame)
@test occursin(Sys.STDLIB, desc)

import InteractiveUtils
@testset "`o` command" begin
    g() = nothing
    LINE = (@__LINE__) - 1
    frame = Debugger.@make_frame g()
    state = dummy_state(frame)
    JuliaInterpreter.breakpoint(InteractiveUtils.edit)
    frame, bp = JuliaInterpreter.@interpret execute_command(state, Val{:o}(), "o")
    JuliaInterpreter.remove()
    locals = JuliaInterpreter.locals(frame)
    @test JuliaInterpreter.Variable(@__FILE__, :file, false) in locals
    @test JuliaInterpreter.Variable(LINE, :line, false) in locals
end

# Breakpoints
frame = Debugger.@make_frame sin(1.0)
state = dummy_state(frame)

# add
execute_command(state, Val{:bp}(), "bp add cos")
bp = breakpoints()[1]
@test bp.f === cos
@test bp.sig === nothing
@test bp.condition === nothing
@test bp.line == 0
execute_command(state, Val{:bp}(), "bp rm")
@test length(breakpoints()) == 0
execute_command(state, Val{:bp}(), "bp add cos(x)")
bp = breakpoints()[1]
@test bp.f === cos
@test bp.sig == Tuple{typeof(cos), Float64}
JuliaInterpreter.remove()

execute_command(state, Val{:bp}(), "bp add cos(::Float32)")
bp = breakpoints()[1]
@test bp.f == cos
@test bp.sig == Tuple{typeof(cos), Float32}
JuliaInterpreter.remove()

TT = Float32
execute_command(state, Val{:bp}(), "bp add cos(::TT)")
bp = breakpoints()[1]
@test bp.f == cos
@test bp.sig == Tuple{typeof(cos), Float32}
JuliaInterpreter.remove()

execute_command(state, Val{:bp}(), """bp add "foo.jl":10 x>3""")
bp = breakpoints()[1]
@test bp.path == "foo.jl"
@test bp.line == 10
@test bp.condition == :(x > 3)
JuliaInterpreter.remove()

execute_command(state, Val{:bp}(), """bp add 10""")
bp = breakpoints()[1]
@test bp.line == 10
@test bp.path == CodeTracking.whereis(@which sin(1.0))[1]
JuliaInterpreter.remove()

execute_command(state, Val{:bp}(), """bp add Base.cos:5""")
bp = breakpoints()[1]
@test bp.f === cos
@test bp.line == 5
JuliaInterpreter.remove()

execute_command(state, Val{:bp}(), """bp add Base.sin(x)""")
bp = breakpoints()[1]
@test bp.f === sin
@test bp.sig == Tuple{typeof(sin), Float64}
JuliaInterpreter.remove()

execute_command(state, Val{:bp}(), """bp add Base.sin(x):10""")
bp = breakpoints()[1]
@test bp.f === sin
@test bp.sig == Tuple{typeof(sin), Float64}
@test bp.line == 10
JuliaInterpreter.remove()

execute_command(state, Val{:bp}(), """bp add 1+1""")
bp = breakpoints()[1]
@test bp.f === +
@test bp.sig == Tuple{typeof(+), Int, Int}
JuliaInterpreter.remove()

# toggle
execute_command(state, Val{:bp}(), """bp add sin""")
execute_command(state, Val{:bp}(), """bp add cos""")
execute_command(state, Val{:bp}(), """bp toggle 1""")
bp = breakpoints()[1]
bp2 = breakpoints()[2]
@test bp.enabled[] == false
@test bp2.enabled[] == true
execute_command(state, Val{:bp}(), """bp toggle""")
@test bp.enabled[] == true
@test bp2.enabled[] == false
JuliaInterpreter.remove()

# disable / enable
execute_command(state, Val{:bp}(), """bp add sin""")
execute_command(state, Val{:bp}(), """bp add cos""")
execute_command(state, Val{:bp}(), """bp disable 1""")
bp = breakpoints()[1]
bp2 = breakpoints()[2]
@test bp.enabled[] == false
execute_command(state, Val{:bp}(), """bp enable 1""")
@test bp.enabled[] == true
execute_command(state, Val{:bp}(), """bp disable""")
@test bp.enabled[] == false
@test bp2.enabled[] == false
JuliaInterpreter.remove()

frame = Debugger.@make_frame 1.0:2.0:3.0
state = dummy_state(frame)
execute_command(state, Val{:bp}(), """bp add StepRangeLen""")
execute_command(state, Val{:c}(), "c")
@test state.frame !== nothing
JuliaInterpreter.remove()

@info "BEGIN ERRORS -------------------------------------"
execute_command(state, Val{:bp}(), """bp add Base""")
@test length(breakpoints()) == 0
execute_command(state, Val{:bp}(), """bp add lfdshfds""")
@test length(breakpoints()) == 0
@info "END ERRORS -------------------------------------"

@testset "_iscall" begin
    @test _iscall(:(1 + 2))
    @test _iscall(:($(Symbol(".f"))(1, 2)))
    @test _iscall(:(f(1, 2)))
    @test _iscall(:($(+)(1, 2)))
    @test !_iscall(:(1 .+ 2))
    @test !_iscall(:(f.(1, 2)))
    @test !_iscall(:(identity() do; end))
end

# Issue #134: a breakpoint on one of the initial statements of a function should
# not be stepped over when entering the frame
@testset "breakpoint on first statement" begin
    function f_bp_first(x)
        y = x + 1
        return y * 2
    end
    JuliaInterpreter.breakpoint(f_bp_first)
    try
        frame = @make_frame f_bp_first(1)
        @test JuliaInterpreter.shouldbreak(frame, frame.pc)
    finally
        JuliaInterpreter.remove()
    end
end

# Issue #394: backslash (latex) completions in the evaluation mode
@testset "completions" begin
    f_completions(x) = x + 1
    frame = @make_frame f_completions(1)
    provider = Debugger.DebugCompletionProvider(dummy_state(frame))
    ret, _, _ = Debugger.completions(provider, "\\Omega", "\\Omega")
    @test ret == ["Ω"]
    ret, _, _ = Debugger.completions(provider, "x", "x")
    @test "x" in ret
end

# Issue #352: a function breakpoint can stop on a bare quoted value; it should
# not be displayed as `$(QuoteNode(f))`
@testset "no QuoteNode in next expression display" begin
    g352() = IOBuffer()
    function f352()
        x = g352()
        println(x, "hello")
    end
    JuliaInterpreter.breakpoint(println)
    try
        frame = @make_frame f352()
        state = dummy_state(frame)
        execute_command(state, Val{:c}(), "c")
        out = sprint(Debugger.print_next_expr, JuliaInterpreter.leaf(state.frame))
        @test !occursin("QuoteNode", out)
    finally
        JuliaInterpreter.remove()
    end
end

@testset "p command" begin
    function command_output(frame, cmd)
        buf = IOBuffer()
        term = REPL.Terminals.TTYTerminal("dumb", stdin, buf, stderr)
        state = Debugger.DebuggerState(; frame=frame, terminal=term)
        execute_command(state, Val{Symbol(first(split(cmd)))}(), cmd)
        return String(take!(buf))
    end
    f_p_cmd(x) = (y = x + 1; y * 2)
    frame = @make_frame f_p_cmd(3)
    @test occursin("x::$Int = 3", command_output(frame, "p x"))
    @test occursin("x::$Int = 3", command_output(frame, "p"))
    @test occursin("no variable `nope` in this frame", command_output(frame, "p nope"))
end

# Issue #338: the two completion passes (frame module / locals) can return
# completions of different kinds with different replacement ranges; they must
# not be merged into one broken list
struct S_completions
    field_a
    field_b
end
@testset "completion merging" begin
    function f_completions_merge()
        xs = [S_completions(1, 2)]
        d = Dict("key1" => 1)
        return (xs, d)
    end
    frame = @make_frame f_completions_merge()
    state = dummy_state(frame)
    execute_command(state, Val{:sr}(), "sr")
    provider = Debugger.DebugCompletionProvider(state)
    # dict key completion for a local dict is not polluted by path completions
    ret, _, _ = Debugger.completions(provider, "d[\"", "d[\"")
    @test ret == ["\"key1\"]"]
    # field completion through getindex inference on a local
    ret, _, _ = Debugger.completions(provider, "xs[1].", "xs[1].")
    @test ret == ["field_a", "field_b"]
    # identifier completions from the frame module and the locals are merged
    ret, _, _ = Debugger.completions(provider, "si", "si")
    @test "sin" in ret
    ret, _, _ = Debugger.completions(provider, "xs", "xs")
    @test "xs" in ret
end
