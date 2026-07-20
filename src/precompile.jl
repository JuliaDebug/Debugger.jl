# Run a small scripted debugger session during package precompilation, so that
# first use does not pay for compiling the session machinery (`RunDebugger` and
# its LineEdit closures, stepping commands, status printing, syntax
# highlighting).

using PrecompileTools: @compile_workload

# A minimal terminal that LineEdit can drive non-interactively
mutable struct _PrecompileTerminal <: REPL.Terminals.UnixTerminal
    in_stream::IOBuffer
    out_stream::IOBuffer
    err_stream::IOBuffer
end
REPL.Terminals.raw!(::_PrecompileTerminal, ::Bool) = true
REPL.Terminals.hascolor(::_PrecompileTerminal) = true
Base.displaysize(::_PrecompileTerminal) = (24, 80)

# Keyword arguments so that the kwarg wrapper/body machinery is exercised too
function _precompile_target(x, y; z = 3)
    a = x + y
    s = "a string"
    v = [1.0, 2.0, 3.0]
    b = sin(a) * z + sum(v)
    return b * π
end

@compile_workload begin
    try
        input = IOBuffer("n\nnc\nst\nbt\nfr\np a\nw add a + 1\nw rm\nc\n")
        term = _PrecompileTerminal(input, IOBuffer(), IOBuffer())
        repl = REPL.LineEditREPL(term, true)
        repl.interface = REPL.setup_interface(repl)
        frame = @make_frame _precompile_target(2, 3)
        RunDebugger(frame, repl, term)
        install_repl_mode(repl)
        debug_mode_parse("sin(1.0)")
        debug_mode_parse("bp add f")
    catch err
        @warn "Debugger precompile workload failed" exception=(err, catch_backtrace())
    end
    # `@enter`/`@run` call the one-argument method (the terminal comes from the
    # active REPL), which the scripted session above does not exercise
    precompile(RunDebugger, (Frame,))

    # Clean up global state the workload mutated. The highlight cache in
    # particular holds tree-sitter pointers that must not be serialized into
    # the package image.
    _highlight_cache[] = nothing
    empty!(WATCH_LIST)
    JuliaInterpreter.remove()
    _ALT_SCREEN[] = false
end
