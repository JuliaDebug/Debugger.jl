function CallTest()
    UnitRange{Int64}(2,2)
end

step_through(enter_call_expr(:($(CallTest)())))

# Properly handle :meta annotations
function MetaTest()
    @Base._pure_meta
    0
end

step_through(enter_call_expr(:($(MetaTest)())))

# Test Vararg handling
function VATest(x...)
    x
end
callVA() = VATest()

step_through(enter_call_expr(:($(VATest)())))

# Test Loops
function LoopTest()
    x = Int[]
    for i = 1:2
        push!(x, i)
    end
    x
end

step_through(enter_call_expr(:($(LoopTest)())))

# Test continue
function ContinueTest()
    x = Int[]
    for i = 1:3
        if true
            push!(x, i)
            continue
        end
        error("Fell through")
    end
    x
end

step_through(enter_call_expr(:($(ContinueTest)())))

#foo() = 1+1
function foo(n)
    x = n+1
    ((BigInt[1 1; 1 0])^x)[2,1]
end


step_through(enter_call_expr(:($(foo)(20))))

# Make sure that Symbols don't get an extra QuoteNode
function foo_sym()
    x = :ok
    typeof(x)
end

@test step_through(enter_call_expr(:($(foo_sym)()))) == Symbol

# Make sure evalling "new" works with symbols

function new_sym()
  a = :a
  () -> a
end

step_through(enter_call_expr(:($new_sym())))