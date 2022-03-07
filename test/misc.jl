# Issue #14

using Debugger: _iscall
using JuliaInterpreter: JuliaInterpreter, pc_expr, evaluate_call!, finish_and_return!, @lookup, enter_call_expr, breakpoints
runframe(frame::Frame, pc=frame.pc[]) = Some{Any}(finish_and_return!(Compiled(), frame))

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
    Debugger.set_highlight(Debugger.HIGHLIGHT_SYSTEM_COLORS)
    frame = Debugger.@make_frame f()
    st = chomp(sprint(Debugger.print_status, frame; context = :color => true))
    x_1_plus_1_colored = "x \e[91m=\e[39m 1 \e[91m+\e[39m"
    @test occursin(x_1_plus_1_colored, st)

    frame = Debugger.@make_frame f_unicode()
    st = chomp(sprint(Debugger.print_status, frame; context = :color => true))
    @test occursin("√", st)
finally
    Debugger.set_highlight(Debugger.HIGHLIGHT_OFF)
end

frame = @make_frame Test.eval(1)
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
