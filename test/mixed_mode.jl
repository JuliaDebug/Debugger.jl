module MixedModeTests

using Debugger: Debugger, MixedInterpreter, run_native, carries_focus_code,
                native_suppressed_reason, compile_module!, interpret_module!,
                interpreted_modules, interp_for_mode, set_default_mode!, default_mode,
                focus_module!, unfocus_module!, seed_focus!, is_focus_module
using JuliaInterpreter
using JuliaInterpreter: debug_command, BreakpointRef, @bp
import CodeTracking
import REPL
using Test

struct MyT
    x::Int
end
struct MyCallable end
(::MyCallable)(x) = x + 1
user_f(x) = 2x

inner(x) = x * 2
map_entry(xs) = sum(map(inner, xs)) + length(xs)
sortby_entry(xs) = sort(xs; by = inner)
bcast_entry(xs) = inner.(xs)
doblock_entry() = sprint(io -> print(io, inner(3)))
splat_entry(xs) = inner(xs...)
gcd_entry() = gcd(10, 20) + 0
sum_entry(x) = sum(abs2, 1:x) + 1
catcher() = try
    sqrt(-1.0)
catch
    42
end
bp_cb(x) = (@bp; x + 1)
bp_entry(xs) = sum(map(bp_cb, xs))
const ji_breakpoints = JuliaInterpreter.breakpoints
ji_entry() = ji_breakpoints() isa Vector
gcd_step_entry() = gcd(4, 6) > 0

mkstate(frame) = Debugger.DebuggerState(frame = frame)

fresh_suppression!() = (Debugger._bp_suppression_computed[] = false)

@testset "policy: carries_focus_code" begin
    @test !carries_focus_code(sin)
    @test !carries_focus_code([1, 2, 3])
    @test !carries_focus_code("abc")
    @test !carries_focus_code(Union{Int, Missing}[])
    @test !carries_focus_code(AbstractVector)
    @test carries_focus_code(user_f)
    @test carries_focus_code(MyT)                       # constructors are not DataType/Core
    @test carries_focus_code(MyCallable())              # callable struct
    @test carries_focus_code(MyT[])                     # user type as type parameter
    @test carries_focus_code(AbstractVector{MyT})
    @test carries_focus_code(Base.Generator(user_f, [1]))
    @test carries_focus_code((by = user_f,))            # keyword-call NamedTuple
    @test carries_focus_code(Val(user_f))               # value type parameter
    @test carries_focus_code(Val((user_f,)))            # focus function inside a tuple value parameter
    @test !carries_focus_code(Val((1, 2)))
    @test carries_focus_code(TypeVar(:T, Union{}, MyT)) # TypeVar value with focus bound
    @test carries_focus_code(Vararg{MyT})               # top-level Vararg value
    @test !carries_focus_code(Vararg{Int})
    # Registered dependencies are not in focus; a devved JuliaInterpreter is.
    ji_focused = is_focus_module(Base.moduleroot(JuliaInterpreter))
    @test carries_focus_code(JuliaInterpreter.breakpoints) == ji_focused
    @test carries_focus_code(JuliaInterpreter.BreakpointRef[]) == ji_focused
    # modules and GlobalRefs can smuggle focus code without focus-typed args
    @test carries_focus_code(Main)
    @test carries_focus_code(@__MODULE__)
    @test !carries_focus_code(Base)
    @test carries_focus_code(GlobalRef(Main, :x))
    @test !carries_focus_code(GlobalRef(Base, :sin))
end

@testset "path containment" begin
    @test Debugger._path_within("/a/packages/X", "/a/packages")
    @test Debugger._path_within("/a/packages", "/a/packages")
    @test !Debugger._path_within("/a/packages-dev/X", "/a/packages")
end

@testset "policy: run_native" begin
    @test run_native(Any[sort, [3, 1, 2]])
    @test !run_native(Any[map, user_f, [1, 2]])
    @test !run_native(Any[MyT, 1])
    @test !run_native(Any[Core.kwcall, (by = user_f,), sort, [3, 1, 2]])
    # Registered dependencies run natively; devved dependencies stay interpretable.
    ji_focused = is_focus_module(Base.moduleroot(JuliaInterpreter))
    @test run_native(Any[JuliaInterpreter.breakpoints]) == !ji_focused
    @test run_native(Any[map, JuliaInterpreter.leaf, JuliaInterpreter.Frame[]]) == !ji_focused
    # documented limitation: type-erased containers hide user code
    @test run_native(Any[foreach, print, Any[user_f]])
end

@testset "focus set" begin
    mods = interpreted_modules()
    @test Main ∈ mods                       # test module's root is Main
    @test Base ∉ mods && Core ∉ mods
    ji_is_dev = Debugger.is_dev_package(JuliaInterpreter)
    @test (JuliaInterpreter ∈ mods) == ji_is_dev
    # under PkgEval Debugger itself is a registered install, so compare rather than assert
    @test (Debugger ∈ mods) == Debugger.is_dev_package(Debugger)

    # session-scoped add/remove
    unfocus_module!(JuliaInterpreter)
    @test focus_module!(JuliaInterpreter)
    @test JuliaInterpreter ∈ interpreted_modules()
    @test !run_native(Any[JuliaInterpreter.breakpoints])
    @test unfocus_module!(JuliaInterpreter)
    @test run_native(Any[JuliaInterpreter.breakpoints])

    # permanent overrides
    try
        compile_module!(@__MODULE__)   # root is Main
        @test run_native(Any[user_f, 1])
        interpret_module!(@__MODULE__)
        @test !run_native(Any[user_f, 1])
    finally
        delete!(Debugger.COMPILE_OVERRIDES, Base.moduleroot(@__MODULE__))
        delete!(Debugger.INTERPRET_OVERRIDES, Base.moduleroot(@__MODULE__))
        Debugger.FOCUS[] = nothing
        Debugger.invalidate_policy_cache!()
    end
    @test !run_native(Any[user_f, 1])
end

@testset "focus seeding" begin
    # entering a dependency function focuses its package
    frame = JuliaInterpreter.enter_call(CodeTracking.maybe_fix_path, "/no/such/path.jl")
    seed_focus!(frame)
    @test CodeTracking ∈ interpreted_modules()
    # entering a Base function does not drag Base into focus, but it is
    # remembered (hint printed once) and offered as a row in the focus menu.
    # The hint is once-per-process; earlier tests may have stepped into Base
    delete!(Debugger._stdlib_focus_hinted, Base)
    Debugger._pending_entry_hint[] = nothing
    frame = JuliaInterpreter.enter_call(gcd, 10, 20)
    seed_focus!(frame)
    @test Base ∉ interpreted_modules()
    @test CodeTracking ∉ interpreted_modules()  # reseed dropped the previous entry root
    @test Main ∈ interpreted_modules()
    @test Base ∈ Debugger._stdlib_focus_hinted
    @test Base ∈ Debugger.focus_menu_rows()
    # the hint is stashed at seed time (printing there would be swallowed by
    # the alternate-screen switch) and printed after the first status draw
    @test Debugger._pending_entry_hint[] === Base
    term = REPL.Terminals.TTYTerminal("xterm", IOBuffer(), IOBuffer(), IOBuffer())
    st = Debugger.DebuggerState(frame = nothing, terminal = term)
    Debugger.maybe_print_entry_hint(st)
    @test occursin("focus add Base", String(take!(term.out_stream)))
    @test Debugger._pending_entry_hint[] === nothing
end

@testset "JuliaInterpreter.interpreted_methods precedence" begin
    m = which(sort, (Vector{Int},))
    push!(JuliaInterpreter.interpreted_methods, m)
    try
        @test !run_native(Any[sort, [3, 1, 2]])
    finally
        delete!(JuliaInterpreter.interpreted_methods, m)
    end
    @test run_native(Any[sort, [3, 1, 2]])
end

@testset "breakpoint suppression" begin
    JuliaInterpreter.remove(); fresh_suppression!()
    @test native_suppressed_reason() === nothing

    # breakpoints in user code do not suppress the fast path
    bp = JuliaInterpreter.breakpoint(inner); fresh_suppression!()
    @test native_suppressed_reason() === nothing
    JuliaInterpreter.remove(bp)
    bp = JuliaInterpreter.breakpoint(MyT); fresh_suppression!()
    @test native_suppressed_reason() === nothing
    JuliaInterpreter.remove(bp)

    # breakpoints in compiled modules suppress it
    bp = JuliaInterpreter.breakpoint(sort); fresh_suppression!()
    @test native_suppressed_reason() !== nothing
    @test !run_native(Any[sort, [3, 1, 2]])
    JuliaInterpreter.remove(bp); fresh_suppression!()
    @test native_suppressed_reason() === nothing

    # disabled breakpoints do not suppress
    bp = JuliaInterpreter.breakpoint(sort)
    JuliaInterpreter.disable(bp); fresh_suppression!()
    @test native_suppressed_reason() === nothing
    JuliaInterpreter.remove(bp)

    # break_on suppresses
    JuliaInterpreter.break_on(:error)
    @test native_suppressed_reason() !== nothing
    JuliaInterpreter.break_off(:error); fresh_suppression!()
    @test native_suppressed_reason() === nothing

    # a breakpoint in a focus package that loaded non-focus packages depend on
    # also suppresses (native JuliaInterpreter code can reach CodeTracking)
    @test Debugger._has_nonfocus_reverse_dep(CodeTracking)
    @test !Debugger._has_nonfocus_reverse_dep(Debugger)
    try
        focus_module!(CodeTracking)
        bp = JuliaInterpreter.breakpoint(CodeTracking.maybe_fix_path); fresh_suppression!()
        @test occursin("depend on", something(native_suppressed_reason(), ""))
        JuliaInterpreter.remove(bp)
    finally
        unfocus_module!(CodeTracking)
        empty!(Debugger.SESSION_UNFOCUSED)
        fresh_suppression!()
    end
    @test native_suppressed_reason() === nothing
end

@testset "reset_module!" begin
    try
        compile_module!(@__MODULE__)   # root is Main
        @test Main ∉ interpreted_modules()
        focus_module!(JuliaInterpreter) # unrelated session choice
        Debugger.reset_module!(@__MODULE__)
        @test Main ∈ interpreted_modules()
        @test JuliaInterpreter ∈ interpreted_modules() # survived the reset
    finally
        delete!(Debugger.COMPILE_OVERRIDES, Main)
        Debugger.FOCUS[] = nothing
        empty!(Debugger.SESSION_UNFOCUSED)
        Debugger.invalidate_policy_cache!()
    end
end

@testset "julia internals are not auto-focused" begin
    if isdefined(Base, :Compiler)
        @test Debugger.is_stdlib_root(Base.moduleroot(Base.Compiler))
    end
    # ...but a user module that happens to be named Compiler is
    @test !Debugger.is_stdlib_root(Module(:Compiler))
end

@testset "reset_module! keeps the entered package focused" begin
    try
        frame = JuliaInterpreter.enter_call(CodeTracking.maybe_fix_path, "/no/such/path.jl")
        seed_focus!(frame)
        @test CodeTracking ∈ interpreted_modules()  # focused as the entry root
        compile_module!(CodeTracking)
        @test CodeTracking ∉ interpreted_modules()
        Debugger.reset_module!(CodeTracking)
        @test CodeTracking ∈ interpreted_modules()  # entry-root focus restored

        # same but with the override in place before the session starts
        compile_module!(CodeTracking)
        frame = JuliaInterpreter.enter_call(CodeTracking.maybe_fix_path, "/no/such/path.jl")
        seed_focus!(frame)
        @test CodeTracking ∉ interpreted_modules()  # override wins at seed time
        Debugger.reset_module!(CodeTracking)
        @test CodeTracking ∈ interpreted_modules()  # entry root remembered anyway
    finally
        delete!(Debugger.COMPILE_OVERRIDES, CodeTracking)
        Debugger.SESSION_ENTRY_ROOT[] = nothing
        Debugger.FOCUS[] = nothing
        Debugger.invalidate_policy_cache!()
    end
end

@testset "file breakpoint path classification" begin
    mkbp(path) = JuliaInterpreter.BreakpointFileLocation(
        path, CodeTracking.maybe_fix_path(abspath(path)), 1, nothing, Ref(true), BreakpointRef[])
    # relative paths match by suffix against any file, including Base sources
    @test Debugger._filebp_could_target_compiled(mkbp("sort.jl"))
    @test !Debugger._filebp_could_target_compiled(mkbp("surely_not_a_base_file.jl"))
    base_sort = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base", "sort.jl")
    @test Debugger._filebp_could_target_compiled(mkbp(base_sort))
    userfile = joinpath(mktempdir(), "userscript.jl")
    write(userfile, "f() = 1\n")
    @test !Debugger._filebp_could_target_compiled(mkbp(userfile))

    bp = JuliaInterpreter.breakpoint(userfile, 1); fresh_suppression!()
    @test native_suppressed_reason() === nothing
    JuliaInterpreter.remove(bp)
end

function break_leaf_scope(entry, args...)
    frame = JuliaInterpreter.enter_call(entry, args...)
    ret = debug_command(MixedInterpreter(), frame, :c)
    ret === nothing && return nothing
    frame2, pc = ret
    pc isa BreakpointRef || return nothing
    return JuliaInterpreter.scopeof(JuliaInterpreter.leaf(frame2)).name
end

@testset "breakpoints in user callbacks fire through Base higher-order functions" begin
    JuliaInterpreter.breakpoint(inner)
    try
        @test break_leaf_scope(map_entry, [1, 2, 3]) === :inner
        @test break_leaf_scope(sortby_entry, [3, 1, 2]) === :inner
        @test break_leaf_scope(bcast_entry, [1, 2, 3]) === :inner
        @test break_leaf_scope(doblock_entry) === :inner
        @test break_leaf_scope(splat_entry, (3,)) === :inner
    finally
        JuliaInterpreter.remove()
        fresh_suppression!()
    end
end

@testset "breakpoint in Base fires because suppression interprets everything" begin
    JuliaInterpreter.breakpoint(gcd)
    try
        @test break_leaf_scope(gcd_entry) === :gcd
    finally
        JuliaInterpreter.remove()
        fresh_suppression!()
    end
end

@testset "native execution is correct" begin
    frame = JuliaInterpreter.enter_call(sum_entry, 10)
    @test debug_command(MixedInterpreter(), frame, :finish) === nothing
    @test JuliaInterpreter.get_return(frame) == sum(abs2, 1:10) + 1

    # an error thrown inside a native call is caught by the interpreted caller
    frame = JuliaInterpreter.enter_call(catcher)
    @test debug_command(MixedInterpreter(), frame, :finish) === nothing
    @test JuliaInterpreter.get_return(frame) == 42
end

@testset "@bp fires through Base higher-order functions" begin
    frame = JuliaInterpreter.enter_call(bp_entry, [1, 2])
    ret = debug_command(MixedInterpreter(), frame, :c)
    @test ret !== nothing && ret[2] isa BreakpointRef
    @test JuliaInterpreter.scopeof(JuliaInterpreter.leaf(ret[1])).name === :bp_cb
end

@testset "focus grows on step-in" begin
    Debugger.FOCUS[] = nothing
    Debugger.invalidate_policy_cache!()
    try
        # stepping into a dependency package adds it to the session focus set
        state = mkstate(JuliaInterpreter.enter_call(ji_entry))
        @test state.interp isa MixedInterpreter
        Debugger.execute_command(state, Val{:s}(), "s")
        @test JuliaInterpreter ∈ interpreted_modules()
        # stepping into Base does not
        state = mkstate(JuliaInterpreter.enter_call(gcd_step_entry))
        Debugger.execute_command(state, Val{:s}(), "s")
        @test Base ∉ interpreted_modules()
    finally
        Debugger.FOCUS[] = nothing
        Debugger.invalidate_policy_cache!()
    end
end

@testset "modes" begin
    @test default_mode() === :mixed
    @test interp_for_mode(:interpreted) isa JuliaInterpreter.RecursiveInterpreter
    @test interp_for_mode(:mixed) isa MixedInterpreter
    @test interp_for_mode(:compiled) isa JuliaInterpreter.NonRecursiveInterpreter
    @test_throws ArgumentError interp_for_mode(:bogus)
    @test_throws ArgumentError set_default_mode!(:bogus)
    state = Debugger.DebuggerState(frame = nothing)
    @test state.interp isa MixedInterpreter
    try
        set_default_mode!(:interpreted)
        state = Debugger.DebuggerState(frame = nothing)
        @test state.interp isa JuliaInterpreter.RecursiveInterpreter
    finally
        set_default_mode!(:mixed)
    end
    # M toggles interpreted and back; C toggles compiled and back
    state = Debugger.DebuggerState(frame = nothing)
    Debugger.toggle_mixed(state)
    @test state.interp isa JuliaInterpreter.RecursiveInterpreter
    Debugger.toggle_mixed(state)
    @test state.interp isa MixedInterpreter
    Debugger.toggle_mode(state)
    @test state.interp isa JuliaInterpreter.NonRecursiveInterpreter
    Debugger.toggle_mode(state)
    @test state.interp isa MixedInterpreter
    # `mode compiled` followed by `C` returns to the previous mode too
    Debugger.set_session_mode!(state, :compiled)
    @test state.interp isa JuliaInterpreter.NonRecursiveInterpreter
    Debugger.toggle_mode(state)
    @test state.interp isa MixedInterpreter
end

end # module MixedModeTests
