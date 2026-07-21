# Mixed-mode execution: run "boring" calls (Base/stdlib code operating purely on
# Base/stdlib data) natively, while interpreting every call that could lead to user
# code — user functions passed as arguments (also inside wrappers like `Generator`,
# `Broadcasted` or keyword-call `NamedTuple`s) and calls that may dispatch on user
# types.
#
# All policy state below is process-global and unsynchronized, like the rest of
# Debugger/JuliaInterpreter (breakpoints, WATCH_LIST, compiled_methods): one debug
# session at a time is assumed; nested or concurrent sessions share and reseed it.

"""
    MixedInterpreter <: JuliaInterpreter.Interpreter

An interpreter that recurses (like `RecursiveInterpreter`) into any call that can
reach user code, but executes calls natively (like `NonRecursiveInterpreter`) when
both the callee and all arguments belong to "compiled" modules (by default `Core`,
`Base` and the standard libraries). See `Debugger.compile_module!`,
`Debugger.interpret_module!` and the `mode` debugger command.
"""
struct MixedInterpreter <: Interpreter end

# ------------------------------------------------------------------
# Module classification: the focus set
# ------------------------------------------------------------------

# Mixed mode interprets the modules being debugged — the "focus set" — and runs
# everything else (Base, stdlibs *and* dependency packages) natively when possible.
# The focus set is seeded per debug session: `Main`, packages loaded from dev
# checkouts (a `pkgdir` outside every depot's read-only `packages/` store), the
# root module of the entered method, and the permanent overrides below.

const STDLIB_NAMES = Set{Symbol}()
const COMPILE_OVERRIDES = Set{Module}()   # roots forced out of focus via compile_module!
const INTERPRET_OVERRIDES = Set{Module}() # roots forced into focus via interpret_module!
const FOCUS = Ref{Union{Nothing,Set{Module}}}(nothing) # nothing = seed on first use
const _dev_package_cache = Dict{Module,Bool}()

# julia's compiler is a separate root module on ≥1.12; matched by identity so a
# user package that happens to be called `Compiler` is not misclassified
const _compiler_root = Ref{Union{Nothing,Module}}(nothing)

is_stdlib_root(root::Module) =
    root === Base || root === Core || nameof(root) ∈ STDLIB_NAMES ||
    root === _compiler_root[]

_maybe_realpath(path::String) = try realpath(path) catch; normpath(path) end

# Component-aware containment: `packages-dev` is not inside `packages`.
_path_within(path::String, dir::String) = path == dir || startswith(path, joinpath(dir, ""))

_pkg_devdir() = _maybe_realpath(get(ENV, "JULIA_PKG_DEVDIR") do
    joinpath(isempty(DEPOT_PATH) ? joinpath(homedir(), ".julia") : DEPOT_PATH[1], "dev")
end)

# "Dev checkout" — source the user can plausibly be editing/debugging. Registered
# installs live in a depot's content-addressed (read-only) `packages/` store.
function is_dev_package(root::Module)
    get!(_dev_package_cache, root) do
        root === Main && return true
        is_stdlib_root(root) && return false
        dir = pkgdir(root)
        dir === nothing && return true # non-package root, e.g. eval'd module
        rdir = _maybe_realpath(dir)
        _path_within(rdir, _pkg_devdir()) && return true # explicit devdir wins
        for depot in DEPOT_PATH
            pkgs = joinpath(depot, "packages")
            isdir(pkgs) || continue
            _path_within(rdir, _maybe_realpath(pkgs)) && return false
        end
        return !_path_within(rdir, _maybe_realpath(Sys.STDLIB))
    end
end

function default_focus()
    focus = Set{Module}((Main,))
    for (_, m) in Base.loaded_modules
        root = Base.moduleroot(m)
        is_dev_package(root) && push!(focus, root)
    end
    union!(focus, INTERPRET_OVERRIDES)
    setdiff!(focus, COMPILE_OVERRIDES)
    setdiff!(focus, SESSION_UNFOCUSED) # respected on mid-session (lazy) recomputation
    return focus
end

function focus_modules()
    focus = FOCUS[]
    focus === nothing || return focus
    return FOCUS[] = default_focus()
end

is_focus_module(root::Module) = root ∈ focus_modules()
is_compiled_module(root::Module) = !is_focus_module(root)

# Reseed the focus set at the start of a debug session. The entered method's root
# module joins the focus so that `@enter SomePkg.f(...)` makes `SomePkg` debuggable
# even when it is a registered install — except for Base/stdlibs, where focusing
# would de-facto disable the fast path (the entered frame itself is always
# interpreted anyway, so stepping inside it works regardless).
const SESSION_ENTRY_ROOT = Ref{Union{Nothing,Module}}(nothing)
const _pending_entry_hint = Ref{Union{Nothing,Module}}(nothing)

# Printed once per entered stdlib module, after the first status draw of the
# session (a message printed earlier is erased by entering the alternate screen
# in sticky mode).
function maybe_print_entry_hint(state)
    mod = _pending_entry_hint[]
    mod === nothing && return nothing
    _pending_entry_hint[] = nothing
    state.interp isa MixedInterpreter || return nothing
    printstyled(output_stream(state),
                "$mod is not added to the focus set when entered; calls to it from " *
                "other frames still run natively (`focus add $(nameof(mod))` to " *
                "interpret it everywhere)\n"; color=:light_black)
    return nothing
end

function seed_focus!(frame)
    empty!(SESSION_UNFOCUSED) # session choices do not survive into a new session
    SESSION_ENTRY_ROOT[] = nothing
    focus = default_focus()
    scope = frame === nothing ? nothing : JuliaInterpreter.scopeof(root(frame))
    mod = scope isa Method ? scope.module : scope
    if mod isa Module
        entry = Base.moduleroot(mod)
        if !is_stdlib_root(entry)
            # recorded even when overridden, so reset_module! can restore it
            SESSION_ENTRY_ROOT[] = entry
            entry ∉ COMPILE_OVERRIDES && push!(focus, entry)
        elseif entry ∉ INTERPRET_OVERRIDES && entry ∉ _stdlib_focus_hinted
            # entering Base/a stdlib does not focus it (that would de-facto
            # disable the fast path); note it once, and the `focus` menu shows
            # it as a toggleable row. The message itself is printed by
            # `maybe_print_entry_hint` after the first status draw — printing
            # here would be swallowed by the switch to the alternate screen.
            push!(_stdlib_focus_hinted, entry)
            _pending_entry_hint[] = entry
        end
    end
    _loaded_fingerprint[] = length(Base.loaded_modules)
    if FOCUS[] != focus
        FOCUS[] = focus
        invalidate_policy_cache!()
    end
    return focus
end

# Packages can be loaded mid-session (e.g. from the evaluation prompt); newly
# loaded dev packages join the focus set and the source-path caches used for
# file-breakpoint suppression must be rebuilt. Checked once per debugger command.
const _loaded_fingerprint = Ref(-1)

function refresh_loaded_modules!()
    n = length(Base.loaded_modules)
    n == _loaded_fingerprint[] && return nothing
    _loaded_fingerprint[] = n
    if FOCUS[] !== nothing
        for (_, m) in Base.loaded_modules
            root = Base.moduleroot(m)
            if is_dev_package(root) && root ∉ SESSION_UNFOCUSED && root ∉ COMPILE_OVERRIDES
                push!(FOCUS[], root)
            end
        end
    end
    invalidate_policy_cache!()
    return nothing
end

# Session-scoped focus manipulation (the `focus` debugger command). Roots removed
# with `focus rm` are remembered so automatic focus growth does not re-add them.
const SESSION_UNFOCUSED = Set{Module}()

function focus_module!(mod::Module)
    root = Base.moduleroot(mod)
    delete!(SESSION_UNFOCUSED, root)
    added = root ∉ focus_modules()
    added && (push!(focus_modules(), root); invalidate_policy_cache!())
    return added
end

function unfocus_module!(mod::Module)
    root = Base.moduleroot(mod)
    push!(SESSION_UNFOCUSED, root)
    removed = root ∈ focus_modules()
    removed && (delete!(focus_modules(), root); invalidate_policy_cache!())
    return removed
end

"""
    Debugger.compile_module!(mod::Module)

Permanently force `mod` (more precisely, its root module) out of mixed mode's focus
set: calls into it run natively when no argument carries focus code. Note that this
also skips any inline `@bp` markers inside `mod`. For the current session only, use
the `focus rm` debugger command instead.
"""
function compile_module!(mod::Module)
    root = Base.moduleroot(mod)
    delete!(INTERPRET_OVERRIDES, root)
    push!(COMPILE_OVERRIDES, root)
    FOCUS[] === nothing || delete!(FOCUS[], root)
    invalidate_policy_cache!()
    return nothing
end

"""
    Debugger.interpret_module!(mod::Module)

Permanently add `mod` (more precisely, its root module) to mixed mode's focus set:
calls into it, and calls whose arguments carry types from it, are always
interpreted. Use this to debug into a standard library or a registered dependency.
For the current session only, use the `focus add` debugger command instead.
"""
function interpret_module!(mod::Module)
    root = Base.moduleroot(mod)
    delete!(COMPILE_OVERRIDES, root)
    push!(INTERPRET_OVERRIDES, root)
    FOCUS[] === nothing || push!(FOCUS[], root)
    invalidate_policy_cache!()
    return nothing
end

"""
    Debugger.reset_module!(mod::Module)

Remove any permanent [`interpret_module!`](@ref)/[`compile_module!`](@ref) override
for `mod`, returning it to automatic focus classification.
"""
function reset_module!(mod::Module)
    root = Base.moduleroot(mod)
    delete!(COMPILE_OVERRIDES, root)
    delete!(INTERPRET_OVERRIDES, root)
    # reclassify only this root; other session focus choices are kept
    if FOCUS[] !== nothing
        automatic = is_dev_package(root) || root === SESSION_ENTRY_ROOT[]
        if automatic && root ∉ SESSION_UNFOCUSED
            push!(FOCUS[], root)
        else
            delete!(FOCUS[], root)
        end
    end
    invalidate_policy_cache!()
    return nothing
end

"""
    Debugger.interpreted_modules() -> Vector{Module}

Return a snapshot of the current focus set: the root modules mixed mode interprets.
Everything else runs natively when no argument carries focus code. See
[`interpret_module!`](@ref), [`compile_module!`](@ref) and the `focus` debugger
command (mutating the returned vector has no effect).
"""
interpreted_modules() = sort!(collect(focus_modules()); by = m -> string(nameof(m)))

# ------------------------------------------------------------------
# "Does this value carry focus code?" — classification of runtime values
# ------------------------------------------------------------------

# Constructors must be classified by the type they construct, not by
# `typeof(MyT) === DataType` (which would classify them as Core).
classify(@nospecialize x) = x isa Type ? x : typeof(x)

const _usercode_cache = IdDict{Any,Bool}()

function invalidate_policy_cache!()
    empty!(_usercode_cache)
    empty!(_revdep_cache)
    _bp_suppression_computed[] = false
    _suppression_warned[] = false
    _compiled_path_prefixes[] = nothing
    _compiled_source_basenames[] = nothing
    return nothing
end

"""
    carries_focus_code(x) -> Bool

`true` if the runtime value `x` is, or (recursively through its type parameters)
mentions, a function or type from a module in the focus set. Focus `Module`s and
`GlobalRef`s into them also count: their types belong to `Core`, but a callee can
resolve and call focus code through them.
"""
function carries_focus_code(@nospecialize(x))
    x isa Module && return is_focus_module(Base.moduleroot(x))
    x isa GlobalRef && return is_focus_module(Base.moduleroot(x.mod))
    x isa TypeVar && return _carries_user_code(x)
    x isa Core.TypeofVararg && return _carries_user_code(x) # `classify` would erase it
    return _carries_user_code(classify(x))
end

function _carries_user_code(@nospecialize(t))
    r = get(_usercode_cache, t, nothing)
    r !== nothing && return r::Bool
    sawcycle = Ref(false)
    result = _usercode_walk(t, Base.IdSet{Any}(), sawcycle)
    # A result computed under an "assume boring" cycle assumption is not safe to memoize.
    sawcycle[] || (_usercode_cache[t] = result)
    return result
end

function _usercode_walk(@nospecialize(t), inprogress, sawcycle)
    if t isa TypeVar
        return _usercode_walk(t.ub, inprogress, sawcycle) ||
               _usercode_walk(t.lb, inprogress, sawcycle)
    elseif t isa Union
        return _usercode_walk(t.a, inprogress, sawcycle) ||
               _usercode_walk(t.b, inprogress, sawcycle)
    elseif t isa UnionAll
        return _usercode_walk(t.var, inprogress, sawcycle) ||
               _usercode_walk(t.body, inprogress, sawcycle)
    elseif t isa Core.TypeofVararg
        return (isdefined(t, :T) && _usercode_walk(t.T, inprogress, sawcycle)) ||
               (isdefined(t, :N) && _usercode_walk_param(t.N, inprogress, sawcycle))
    elseif t isa DataType
        if t ∈ inprogress
            sawcycle[] = true
            return false
        end
        r = get(_usercode_cache, t, nothing)
        r !== nothing && return r::Bool
        is_compiled_module(Base.moduleroot(t.name.module)) || return true
        push!(inprogress, t)
        try
            for p in t.parameters
                _usercode_walk_param(p, inprogress, sawcycle) && return true
            end
        finally
            delete!(inprogress, t)
        end
        return false
    end
    return false # Union{}, Module, etc.
end

# Type parameters can be types or values; values can be types/modules/tuples that
# carry focus identity their `typeof` would erase (e.g. `Val{(MyT,)}` has the value
# parameter `(MyT,)` whose type is just `Tuple{DataType}`).
function _usercode_walk_param(@nospecialize(p), inprogress, sawcycle)
    if p isa Type || p isa TypeVar || p isa Core.TypeofVararg
        return _usercode_walk(p, inprogress, sawcycle)
    elseif p isa Module
        return !is_compiled_module(Base.moduleroot(p))
    elseif p isa Tuple
        return any(x -> _usercode_walk_param(x, inprogress, sawcycle), p)
    else
        return _usercode_walk(typeof(p), inprogress, sawcycle)
    end
end

# ------------------------------------------------------------------
# Breakpoint-based suppression of the fast path
# ------------------------------------------------------------------

# Native calls create no frames, so a breakpoint inside compiled territory could be
# reached from *any* native call (e.g. LinearAlgebra natively calling into Base).
# The only sound cheap answer is a global one: if any enabled breakpoint could live
# in a compiled module, mixed mode suppresses native execution entirely.
#
# `nothing` means "needs recomputation"; invalidated by the breakpoint-update hook.
const _bp_suppression = Ref{Union{Nothing,String}}(nothing)
const _bp_suppression_computed = Ref(false)
const _suppression_warned = Ref(false)

function _breakpoints_updated_hook(f, bp)
    _bp_suppression[] = nothing
    _bp_suppression_computed[] = false
    _suppression_warned[] = false
    return nothing
end

_scope_root(scope::Method) = Base.moduleroot(scope.module)
_scope_root(scope::Module) = Base.moduleroot(scope)

function _target_root(@nospecialize(f))
    f isa Method && return Base.moduleroot(f.module)
    t = Base.unwrap_unionall(classify(f))
    t isa DataType && return Base.moduleroot(t.name.module)
    return nothing
end

# A breakpoint in a *focus* package is still not safe if a loaded non-focus package
# (transitively) depends on it: a native call into the latter can reach the focus
# package without any focus-typed argument (e.g. registered JuliaInterpreter calling
# a dev'ed CodeTracking). `identify_package(where, name)` answers "is `name` a
# declared dependency of `where`" from the loaded manifest, so walking dependents
# recursively covers chains like non-focus A → focus B → focus M.
const _revdep_cache = Dict{Module,Bool}()

_has_nonfocus_reverse_dep(M::Module) = _revdep_risk(M, Set{Module}())

function _revdep_risk(M::Module, inprogress::Set{Module})
    r = get(_revdep_cache, M, nothing)
    r !== nothing && return r::Bool
    M ∈ inprogress && return false # package graphs are acyclic; guard regardless
    M === Main && return false
    pkgdir(M) === nothing && return false
    target = Base.PkgId(M)
    target.uuid === nothing && return false
    name = String(nameof(M))
    push!(inprogress, M)
    result = false
    seen = Set{Module}()
    for (_, m) in Base.loaded_modules
        R = Base.moduleroot(m)
        (R ∈ seen || R === M || R === Main) && continue
        push!(seen, R)
        pkgid = Base.PkgId(R)
        pkgid.uuid === nothing && continue
        Base.identify_package(pkgid, name) == target || continue
        # R depends on M: native code can reach M if R itself is native (non-focus)
        # or if native code can reach R
        if !is_focus_module(R) || _revdep_risk(R, inprogress)
            result = true
            break
        end
    end
    delete!(inprogress, M)
    return _revdep_cache[M] = result
end

# Source locations of the non-focus ("compiled") modules, used to decide whether a
# file breakpoint could match compiled code: Julia's base and stdlib sources plus
# the package directories of every loaded non-focus root.
const _compiled_path_prefixes = Ref{Union{Nothing,Vector{String}}}(nothing)
const _compiled_source_basenames = Ref{Union{Nothing,Set{String}}}(nothing)

function _compiled_source_dirs()
    dirs = String[normpath(joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia")), Sys.STDLIB]
    seen = Set{Module}()
    for (_, m) in Base.loaded_modules
        root = Base.moduleroot(m)
        root ∈ seen && continue
        push!(seen, root)
        # focus packages are also risky when a loaded non-focus package depends on them
        is_focus_module(root) && !_has_nonfocus_reverse_dep(root) && continue
        d = pkgdir(root)
        d === nothing || push!(dirs, d)
    end
    return unique!(String[_maybe_realpath(d) for d in dirs])
end

function compiled_path_prefixes()
    v = _compiled_path_prefixes[]
    v === nothing || return v
    return _compiled_path_prefixes[] = _compiled_source_dirs()
end

function compiled_source_basenames()
    v = _compiled_source_basenames[]
    v === nothing || return v
    names = Set{String}()
    for dir in compiled_path_prefixes()
        isdir(dir) || continue
        for (_, _, files) in walkdir(dir; onerror = _ -> nothing)
            for f in files
                endswith(f, ".jl") && push!(names, f)
            end
        end
    end
    return _compiled_source_basenames[] = names
end

# Relative file breakpoints match by path suffix against *any* source file (e.g.
# `"sort.jl"` also matches `base/sort.jl`), so only clearly-user paths avoid
# suppressing the fast path.
function _filebp_could_target_compiled(bp)
    if isabspath(bp.path)
        return any(pre -> _path_within(bp.abspath, pre), compiled_path_prefixes())
    else
        return basename(bp.path) ∈ compiled_source_basenames()
    end
end

"""
    native_suppressed_reason() -> Union{Nothing,String}

Return the reason mixed mode is currently running fully interpreted, or `nothing`
if the fast path is active.
"""
function native_suppressed_reason()
    # code may load packages mid-command (e.g. `using` from the evaluation prompt
    # or inside interpreted code); the length check is a cheap no-op otherwise
    refresh_loaded_modules!()
    if JuliaInterpreter.break_on_error[] || JuliaInterpreter.break_on_throw[]
        return "break on error/throw is enabled"
    end
    if !_bp_suppression_computed[]
        _bp_suppression[] = _compute_bp_suppression()
        _bp_suppression_computed[] = true
    end
    return _bp_suppression[]
end

function _bp_target_suppression(root::Union{Module,Nothing}, bp)
    root === nothing && return "breakpoint with unrecognized target: $bp"
    if !is_focus_module(root)
        return "breakpoint set outside the focus set: $bp"
    elseif _has_nonfocus_reverse_dep(root)
        return "breakpoint in $root, which loaded non-focus packages depend on: $bp"
    end
    return nothing
end

function _compute_bp_suppression()
    for bp in JuliaInterpreter.breakpoints()
        bp.enabled[] || continue
        for inst in bp.instances
            reason = _bp_target_suppression(_scope_root(inst.framecode.scope), bp)
            reason === nothing || return reason
        end
        if bp isa JuliaInterpreter.BreakpointSignature
            reason = _bp_target_suppression(_target_root(bp.f), bp)
            reason === nothing || return reason
        elseif bp isa JuliaInterpreter.BreakpointFileLocation
            # Instances only show where the breakpoint has matched *so far*; the
            # path decides whether it could still match compiled code.
            if _filebp_could_target_compiled(bp)
                return "file breakpoint may match outside the focus set: $bp"
            end
        else
            return "unrecognized breakpoint type: $(typeof(bp))"
        end
    end
    return nothing
end

# Focus growth on explicit step-in: landing in a dependency package means the user
# wants to debug it, so it joins the session focus set (announced). Base/stdlib
# frames are routinely passed through on the way into a user callback (e.g. the
# kwarg-body method of `sort(v; by = f)`), so those only get a once-per-module hint
# instead of silently disabling the fast path.
const _stdlib_focus_hinted = Set{Module}()

function maybe_grow_focus!(state)
    state.interp isa MixedInterpreter || return nothing
    frame = state.frame
    frame === nothing && return nothing
    scope = JuliaInterpreter.scopeof(leaf(frame))
    mod = scope isa Method ? scope.module : scope
    mod isa Module || return nothing
    root = Base.moduleroot(mod)
    is_focus_module(root) && return nothing
    if is_stdlib_root(root) || root ∈ COMPILE_OVERRIDES || root ∈ SESSION_UNFOCUSED
        # explicit exclusions win over automatic growth; stdlibs are only hinted
        # because focusing e.g. Base would de-facto disable the fast path
        if root ∉ _stdlib_focus_hinted
            push!(_stdlib_focus_hinted, root)
            printstyled(stderr, "stepped into $root (not added to the focus set; " *
                                "`focus add $(nameof(root))` to interpret it everywhere)\n"; color=:light_black)
        end
    else
        focus_module!(root)
        printstyled(stderr, "added $root to the focus set (it will now be interpreted); " *
                            "`focus rm $(nameof(root))` to undo\n"; color=:light_black)
    end
    return nothing
end

# Called at the start of each stepping command. Recomputes the suppression state
# (the breakpoint-update hook does not fire for e.g. `JuliaInterpreter.remove()`)
# and prints, once per suppression period, why mixed mode is not fast right now.
function maybe_warn_native_suppressed(state)
    state.interp isa MixedInterpreter || return nothing
    _bp_suppression_computed[] = false
    reason = native_suppressed_reason()
    if reason === nothing
        _suppression_warned[] = false
    elseif !_suppression_warned[]
        _suppression_warned[] = true
        printstyled(stderr, "mixed mode running fully interpreted ($reason)\n"; color=:yellow)
    end
    return nothing
end

# ------------------------------------------------------------------
# The policy and the interpreter hook
# ------------------------------------------------------------------

function run_native(fargs::Vector{Any}, world::UInt=Base.get_world_counter())
    native_suppressed_reason() === nothing || return false
    for x in fargs
        carries_focus_code(x) && return false
    end
    # `JuliaInterpreter.interpreted_methods` has documented precedence over any
    # compiled-mode mechanism. It is empty by default, so the method lookup below
    # is not paid in the common case.
    if !isempty(JuliaInterpreter.interpreted_methods)
        sig = Tuple{Base.mapany(JuliaInterpreter._Typeof, fargs)...}
        method = try
            Base.invoke_in_world(world, which, sig)
        catch
            nothing
        end
        method !== nothing && method ∈ JuliaInterpreter.interpreted_methods && return false
    end
    return true
end

function JuliaInterpreter.evaluate_call!(interp::MixedInterpreter, frame::Frame,
                                         fargs::Vector{Any}, enter_generated::Bool)
    f = fargs[1]
    # `Core.eval`, `rethrow` and `Core.invoke` have dedicated handling in the generic
    # method that must not be bypassed by a native call.
    if f === Core.eval || f === Base.rethrow || f === Core.invoke || !run_native(fargs, frame.world)
        return @invoke JuliaInterpreter.evaluate_call!(interp::Interpreter, frame::Frame,
                                                       fargs::Vector{Any}, enter_generated::Bool)
    end
    return JuliaInterpreter.native_call(fargs, frame)
end

# ------------------------------------------------------------------
# Modes
# ------------------------------------------------------------------

const DEFAULT_MODE = Ref{Symbol}(:mixed)

function interp_for_mode(mode::Symbol)
    mode === :interpreted && return RecursiveInterpreter()
    mode === :mixed && return MixedInterpreter()
    mode === :compiled && return NonRecursiveInterpreter()
    throw(ArgumentError("unknown stepping mode :$mode (expected :interpreted, :mixed or :compiled)"))
end

mode_of_interp(::RecursiveInterpreter) = :interpreted
mode_of_interp(::MixedInterpreter) = :mixed
mode_of_interp(::NonRecursiveInterpreter) = :compiled

"""
    Debugger.set_default_mode!(mode::Symbol)

Set the stepping mode future debug sessions start in (suitable for `startup.jl`).
`mode` is one of:

- `:mixed` (default): run Base/stdlib code natively unless the call can reach user
  code (user functions or types among the arguments). Much faster than interpreting
  everything; see the manual for the cases it cannot catch.
- `:interpreted`: interpret everything; breakpoints always work.
- `:compiled`: run everything below the current frame natively (like the `C` toggle).

The mode of a running session is changed with the `mode` debugger command, or the
`M` (mixed) and `C` (compiled) keys.
"""
function set_default_mode!(mode::Symbol)
    interp_for_mode(mode) # validate
    DEFAULT_MODE[] = mode
    return mode
end

"""
    Debugger.default_mode() -> Symbol

The stepping mode new debug sessions start in. See [`set_default_mode!`](@ref).
"""
default_mode() = DEFAULT_MODE[]

# Drop all session/policy state so it is recomputed from scratch. Used by the
# precompile workload (no policy state may be serialized into the pkgimage) and
# defensively at `__init__`.
function reset_mixed_mode_state!()
    FOCUS[] = nothing
    SESSION_ENTRY_ROOT[] = nothing
    _pending_entry_hint[] = nothing
    empty!(SESSION_UNFOCUSED)
    empty!(_dev_package_cache)
    empty!(_stdlib_focus_hinted)
    _loaded_fingerprint[] = -1
    invalidate_policy_cache!()
    return nothing
end

function init_mixed_mode()
    empty!(STDLIB_NAMES)
    for name in readdir(Sys.STDLIB)
        isdir(joinpath(Sys.STDLIB, name)) && push!(STDLIB_NAMES, Symbol(name))
    end
    isdefined(Base, :Compiler) && (_compiler_root[] = Base.moduleroot(Base.Compiler::Module))
    reset_mixed_mode_state!()
    JuliaInterpreter.on_breakpoints_updated(_breakpoints_updated_hook)
    return nothing
end
