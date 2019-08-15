@test step_through(JuliaInterpreter.enter_call_expr(:($(+)(1,2.5)))) == 3.5
@test step_through(JuliaInterpreter.enter_call_expr(:($(sin)(1)))) == sin(1)
@test step_through(JuliaInterpreter.enter_call_expr(:($(gcd)(10,20)))) == gcd(10, 20)

# Step into generated functions
@generated function generatedfoo(T)
    :(return $T)
end
callgenerated() = generatedfoo(1)
frame = JuliaInterpreter.enter_call_expr(:($(callgenerated)()))
state = dummy_state(frame)

# Step into the generated function itself
execute_command(state, Val{:sg}(), "sg")

# Should now be in generated function
execute_command(state, Val{:so}(), "so")

# Now so the regular function
execute_command(state, Val{:so}(), "so")

@test isnothing(state.frame)


# Optional arguments
function optional(n = sin(1))
    x = asin(n)
    cos(x)
end

frame = @make_frame optional()
state = dummy_state(frame)
# asin
execute_command(state, Val{:n}(), "n")
# cos(1.0)
execute_command(state, Val{:n}(), "n")
# return to wrapper
execute_command(state, Val{:n}(), "n")

@test isnothing(state.frame)

# Macros
macro insert_some_calls()
    esc(quote
        x = sin(b)
        y = asin(x)
        z = sin(y)
    end)
end

# Work around the fact that we can't detect macro expansions if the macro
# is defined in the same file
include_string(Main, """
function test_macro()
    a = sin(5)
    b = asin(a)
    @insert_some_calls
    z
end
""","file.jl")

frame = JuliaInterpreter.enter_call_expr(:($(test_macro)()))
state = dummy_state(frame)
# a = sin(5)
execute_command(state, Val{:n}(), "n")
# b = asin(5)
execute_command(state, Val{:n}(), "n")
# @insert_some_calls
execute_command(state, Val{:n}(), "n")
# TODO: Is this right?
execute_command(state, Val{:n}(), "n")
# return z
execute_command(state, Val{:n}(), "n")
execute_command(state, Val{:n}(), "n")
@test isnothing(state.frame)

# Test stepping into functions with keyword arguments
f(x; b = 1) = x+b
g() = f(1; b = 2)
frame = JuliaInterpreter.enter_call_expr(:($(g)()));
state = dummy_state(frame)
# Step to the actual call
execute_command(state, Val{:nc}(), "nc")
execute_command(state, Val{:nc}(), "nc")
execute_command(state, Val{:nc}(), "nc")
# Step in
execute_command(state, Val{:s}(), "s")
# Should get out in two steps
execute_command(state, Val{:so}(), "so")
execute_command(state, Val{:so}(), "so")
@test isnothing(state.frame)

# Test stepping into functions with exception frames
function f_exc()
    try
    catch err
    end
end

function g_exc()
    try
        error()
    catch err
        return err
    end
end

frame = @make_frame f_exc()
state = dummy_state(frame)

execute_command(state, Val{:n}(), "n")
@test isnothing(state.frame)

frame = @make_frame g_exc()
state = dummy_state(frame)

execute_command(state, Val{:n}(), "n")
execute_command(state, Val{:n}(), "n")
@test isnothing(state.frame)
@test state.overall_result isa ErrorException

# Test throwing exception across frames
function f_exc_inner()
    error()
end

function f_exc_outer()
    try
        f_exc_inner()
    catch err
        return err
    end
end

frame = @make_frame f_exc_outer()
state = dummy_state(frame)

execute_command(state, Val{:s}(), "s")
execute_command(state, Val{:n}(), "n")
execute_command(state, Val{:n}(), "n")
@test isnothing(state.frame)
@test state.overall_result isa ErrorException

# Test that symbols don't get an extra QuoteNode
f_symbol() = :limit => true

frame = @make_frame f_symbol()
state = dummy_state(frame)

execute_command(state, Val{:s}(), "s")
execute_command(state, Val{:so}(), "so")
execute_command(state, Val{:so}(), "so")
@test isnothing(state.frame)
@test state.overall_result == f_symbol()

# Test that we can step through varargs
f_va_inner(x) = x + 1
f_va_outer(args...) = f_va_inner(args...)

frame = @make_frame f_va_outer(1)
state = dummy_state(frame)

execute_command(state, Val{:s}(), "s")
execute_command(state, Val{:n}(), "n")
@test ! isnothing(state.frame)
execute_command(state, Val{:so}(), "so")
execute_command(state, Val{:so}(), "so")
@test isnothing(state.frame)
@test state.overall_result == 2

# Test that we step through kw wrappers
f(foo; bar=3) = foo+bar
frame = @make_frame f(2, bar=4)
@test Debugger.stacklength(frame) > 1
state = dummy_state(frame)
execute_command(state, Val{:n}(), "nc")
execute_command(state, Val{:n}(), "nc")
@test isnothing(state.frame)
@test state.overall_result == 6

#= We no longer throw the error since the backtrace is useless, instead we just display it and return
# Test that we throw the right error when stepping through error functions
function foo_error(a,b)
    a > b && error()
    return a*b
end
frame = @make_frame foo_error(3,1)
state = dummy_state(frame)
try
    execute_command(state, Val{:n}(), "n")
catch e
    @test isa(e, ErrorException)
end
=#

# Issue #17
struct B{T} end
function (::B)(y)
    x = 42*y
    return x + y
end

B_inst = B{Int}()
@test step_through(JuliaInterpreter.enter_call_expr(:($(B_inst)(10)))) == 42*10 + 10

# Stepping in non toplevel frames
@info "BEGIN ERRORS -------------------------------------"
f2(x) = f1(x)
f1(x) = x
frame = @make_frame f2(1)
state = dummy_state(frame)
execute_command(state, Val{:s}(), "s")
execute_command(state, Val{:fr}(), "f 2")
@test execute_command(state, Val{:s}(), "s") == false
@test execute_command(state, Val{:n}(), "n") == false
@test execute_command(state, Val{:so}(), "so") == false
@info "END ERRORS ---------------------------------------"

