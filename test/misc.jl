# Issue #14

using JuliaInterpreter: JuliaInterpreter, pc_expr, evaluate_call!, finish_and_return!, @lookup, enter_call_expr
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
defline, current_line, body = Debugger.locinfo(state.frame)
@test occursin("handle_message(logger, level, msg", body)

f_unicode() = √

try
    Debugger.set_highlight(Debugger.HIGHLIGHT_SYSTEM_COLORS)
    frame = Debugger.@make_frame f()
    st = chomp(sprint(Debugger.print_status, frame; context = :color => true))
    x_1_plus_1_colored = "\e[39m\e[97mx\e[39m\e[97m \e[39m\e[91m=\e[39m\e[97m \e[39m1\e[97m \e[39m\e[91m+\e[39m\e[97m \e[39m1\e[97m"
    @test occursin(x_1_plus_1_colored, st)

    frame = Debugger.@make_frame f_unicode()
    @info "The eventual warning below is expected:"
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

# These are LoadError because the error happens at macro expansion
@test_throws LoadError @macroexpand @enter "foo"
@test_throws LoadError @macroexpand @enter 1
@test_throws LoadError @macroexpand @run [1,2]
