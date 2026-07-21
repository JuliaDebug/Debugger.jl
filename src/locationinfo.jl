function body_for_method(current_file, current_line, meth)
    ret = JuliaInterpreter.whereis(meth)
    ret === nothing && return nothing
    deffile, _ = ret
    body_defline = CodeTracking.definition(String, meth)
    if body_defline === nothing
        return (nothing, 1, true)
    else
        body, defline = body_defline
        return (body, defline, deffile != current_file || defline > current_line)
    end
end

# Lowering attributes a function's implicit trailing `return nothing` to the
# line of the preceding statement, which for a function ending in a conditional
# is the last line of a branch that possibly never executed (#342). Detect that
# statement: the final `return nothing`, directly after another `return` with
# the same line attribution (the branch's own return).
function is_phantom_trailing_return(frame::Frame)
    n = JuliaInterpreter.nstatements(frame.framecode)
    frame.pc == n && n > 1 || return false
    returns_nothing(stmt) = begin
        val = stmt isa Core.ReturnNode ? stmt.val :
              isexpr(stmt, :return)    ? stmt.args[1] : missing
        val === nothing || (val isa QuoteNode && val.value === nothing)
    end
    returns_nothing(pc_expr(frame, n)) || return false
    JuliaInterpreter.is_return(pc_expr(frame, n - 1)) || return false
    return JuliaInterpreter.linenumber(frame, n) == JuliaInterpreter.linenumber(frame, n - 1)
end

# The line of the method's closing `end` (or of a one-line definition), or
# `nothing` if the source is unavailable
function method_end_line(meth::Method)
    body_defline = CodeTracking.definition(String, meth)
    body_defline === nothing && return nothing
    body, defline = body_defline
    return defline + countlines(IOBuffer(body)) - 1
end

function locinfo(frame::Frame)
    scope = frame.framecode.scope
    if scope isa Method
        meth = scope
        ret = JuliaInterpreter.whereis(frame)
        ret === nothing && return nothing
        current_file, current_line = ret
        if is_phantom_trailing_return(frame)
            endline = method_end_line(meth)
            endline === nothing || (current_line = endline)
        end
        unknown_start = true
        if JuliaInterpreter.is_generated(meth) && !frame.framecode.generator
            # We're inside the expansion of a generated function.
            # There's not much point trying to query the method.
            # However, me heuristically make one exception: If our
            # src has method_for_inference_heuristics set, it is likely
            # a Cassette pass, so we can use the un-overdubbed method
            # to retrieve source.
            src = frame.framecode.src
            if isdefined(src, :method_for_inference_heuristics)
                (body, defline, unknown_start) = body_for_method(current_file, current_line, src.method_for_inference_heuristics)
            end
        else
            (body, defline, unknown_start) = body_for_method(current_file, current_line, meth)
        end
        if unknown_start
            isfile(current_file) || return nothing
            body = read(current_file, String)
            defline = 1 # We are not sure where the context start in cases like these, could be improved?
        end
        return defline, current_file, current_line, body
    else
        return nothing
    end
end

# Used for the tests
const _print_full_path = Ref(true)

"""
    frame_signature(frame::Frame) -> String

The signature part of a frame description, e.g. `"foo(x, y; c)"`.
"""
function frame_signature(frame::Frame)
    framecode = frame.framecode
    meth = framecode.scope
    meth isa Method || return string("top-level scope in ", framecode.scope)
    return sprint() do io
        argnames = framecode.src.slotnames[2:meth.nargs]
        spectypes = Any[Any for i=1:length(argnames)]

        is_kw = false
        if frame.caller !== nothing
            is_kw = occursin("#kw##", string(frame.caller.framecode.scope))
        end
        if !is_kw
            # A keyword-body method (`#f#n`) has a nameless slot separating the
            # keyword arguments from the positional ones. This also catches the
            # `Core.kwcall` lowering on newer Julia versions, where the caller
            # test above never fires.
            is_kw = any(==(Symbol("")), argnames) && startswith(string(meth.name), "#")
        end
        if is_kw
            i = 0
            for arg in argnames
                if arg == Symbol("")
                    break
                end
                i += 1
            end
            kw_indices = 1:i
            positional_indices = i+2:length(argnames)
        else
            kw_indices = 1:0
            positional_indices = 1:length(argnames)
        end

        methname = string(meth.name)
        if is_kw
            m = match(r"#(.*?)#(?:[0-9]*)$", methname)
            m === nothing || (methname = m.captures[1])
        end
        print(io, methname, '(')
        function print_indices(indices)
            first = true
            for (argname, argT) in zip(argnames[indices], spectypes[indices])
                first || print(io, ", ")
                first = false
                print(io, argname)
                argT === Any || print(io, "::", argT)
            end
        end
        print_indices(positional_indices)
        if !isempty(kw_indices)
            print(io, "; ")
            print_indices(kw_indices)
        end
        print(io, ')')
    end
end

"""
    frame_location(frame::Frame; current_line=false) -> String

The location part of a frame description, e.g. `"foo.jl:12"`. Shows the method
definition line unless `current_line` is `true`.
"""
function frame_location(frame::Frame; current_line::Bool=false)
    meth = frame.framecode.scope
    if meth isa Method
        if current_line
            ret = JuliaInterpreter.whereis(frame)
            file, line = ret === nothing ? (String(meth.file), JuliaInterpreter.linenumber(frame)) : ret
            if is_phantom_trailing_return(frame)
                endline = method_end_line(meth)
                endline === nothing || (line = endline)
            end
        else
            file, line = String(meth.file), meth.line
        end
        path = string(_print_full_path[] ? file : basename(file), ":", line)
        return CodeTracking.maybe_fix_path(path)
    else
        ret = JuliaInterpreter.whereis(frame)
        ret === nothing && return "unknown location"
        file, line = ret
        return string(_print_full_path[] ? file : basename(file), ":", line)
    end
end

locdesc(frame::Frame; current_line::Bool=false) =
    string(frame_signature(frame), " at ", frame_location(frame; current_line=current_line))
