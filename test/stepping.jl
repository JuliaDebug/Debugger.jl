@test step_through(JuliaInterpreter.enter_call_expr(:($(+)(1,2.5)))) == 3.5
@test step_through(JuliaInterpreter.enter_call_expr(:($(sin)(1)))) == sin(1)
@test step_through(JuliaInterpreter.enter_call_expr(:($(gcd)(10,20)))) == gcd(10, 20)

# Step into generated functions
@generated function generatedfoo(T)
    :(return $T)
end
callgenerated() = generatedfoo(1)
frame = JuliaInterpreter.enter_call_expr(:($(callgenerated)()))
state = dummy_state([frame])

# Step into the generated function itself
execute_command(state, state.stack[1], Val{:sg}(), "sg")

# Should now be in generated function
execute_command(state, state.stack[1], Val{:finish}(), "finish")

# Now finish the regular function
execute_command(state, state.stack[1], Val{:finish}(), "finish")

@test isempty(state.stack)


# Optional arguments
function optional(n = sin(1))
    x = asin(n)
    cos(x)
end

frame = JuliaInterpreter.enter_call_expr(:($(optional)()))
state = dummy_state([frame])
# First call steps in
execute_command(state, state.stack[1], Val{:n}(), "n")
# cos(1.0)
execute_command(state, state.stack[1], Val{:n}(), "n")
# return
execute_command(state, state.stack[1], Val{:n}(), "n")

@test isempty(state.stack)

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
state = dummy_state([frame])
# a = sin(5)
execute_command(state, state.stack[1], Val{:n}(), "n")
# b = asin(5)
execute_command(state, state.stack[1], Val{:n}(), "n")
# @insert_some_calls
execute_command(state, state.stack[1], Val{:n}(), "n")
# TODO: Is this right?
execute_command(state, state.stack[1], Val{:n}(), "n")
# return z
execute_command(state, state.stack[1], Val{:n}(), "n")
execute_command(state, state.stack[1], Val{:n}(), "n")
@test isempty(state.stack)

# Test stepping into functions with keyword arguments
f(x; b = 1) = x+b
g() = f(1; b = 2)
frame = JuliaInterpreter.enter_call_expr(:($(g)()));
state = dummy_state([frame])
# Step to the actual call
execute_command(state, state.stack[1], Val{:nc}(), "nc")
execute_command(state, state.stack[1], Val{:nc}(), "nc")
execute_command(state, state.stack[1], Val{:nc}(), "nc")
# Step in
execute_command(state, state.stack[1], Val{:s}(), "s")
# Should get out in two steps
execute_command(state, state.stack[1], Val{:finish}(), "finish")
execute_command(state, state.stack[1], Val{:finish}(), "finish")
@test isempty(state.stack)

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

stack = @make_stack f_exc()
state = dummy_state(stack)

execute_command(state, state.stack[1], Val{:n}(), "n")
@test isempty(state.stack)

stack = @make_stack g_exc()
state = dummy_state(stack)

execute_command(state, state.stack[1], Val{:n}(), "n")
execute_command(state, state.stack[1], Val{:n}(), "n")
@test isempty(state.stack)
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

stack = @make_stack f_exc_outer()
state = dummy_state(stack)

execute_command(state, state.stack[1], Val{:s}(), "s")
execute_command(state, state.stack[1], Val{:n}(), "n")
execute_command(state, state.stack[1], Val{:n}(), "n")
@test isempty(state.stack)
@test state.overall_result isa ErrorException

# Test that symbols don't get an extra QuoteNode
f_symbol() = :limit => true

stack = @make_stack f_symbol()
state = dummy_state(stack)

execute_command(state, state.stack[1], Val{:s}(), "s")
execute_command(state, state.stack[1], Val{:finish}(), "finish")
execute_command(state, state.stack[1], Val{:finish}(), "finish")
@test isempty(state.stack)
@test state.overall_result == f_symbol()

# Test that we can step through varargs
f_va_inner(x) = x + 1
f_va_outer(args...) = f_va_inner(args...)

stack = @make_stack f_va_outer(1)
state = dummy_state(stack)

execute_command(state, state.stack[1], Val{:s}(), "s")
execute_command(state, state.stack[1], Val{:n}(), "n")
@test !isempty(state.stack)
execute_command(state, state.stack[1], Val{:finish}(), "finish")
execute_command(state, state.stack[1], Val{:finish}(), "finish")
@test isempty(state.stack)
@test state.overall_result == 2

# Test that we step through kw wrappers
f(foo; bar=3) = foo+bar
stack = @make_stack f(2, bar=4)
@test length(stack) > 1
state = dummy_state(stack)
execute_command(state, state.stack[1], Val{:n}(), "nc")
execute_command(state, state.stack[1], Val{:n}(), "nc")
@test isempty(state.stack)
@test state.overall_result == 6

# Test that we throw the right error when stepping through error functions
function foo_error(a,b)
    a > b && error()
    return a*b
end
stack = @make_stack foo_error(3,1)
state = dummy_state(stack)
try
    execute_command(state, state.stack[1], Val{:n}(), "n")
catch e
    @test isa(e, ErrorException)
end

# Issue #17
struct B{T} end
function (::B)(y)
    x = 42*y
    return x + y
end

B_inst = B{Int}()
step_through(JuliaInterpreter.enter_call_expr(:($(B_inst)(10))))
