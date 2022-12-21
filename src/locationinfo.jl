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

function locinfo(frame::Frame)
    scope = frame.framecode.scope
    if scope isa Method
        meth = scope
        ret = JuliaInterpreter.whereis(frame)
        ret === nothing && return nothing
        current_file, current_line = ret
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
        println("not yet implemented")
    end
end

# Used for the tests
const _print_full_path = Ref(true)

function locdesc(frame::Frame; current_line=false)
    sprint() do io
        if frame.framecode.scope isa Method
            locdesc(io, frame; current_line=current_line)
        else
            println(io, "not yet implemented")
        end
    end
end

function locdesc(io, frame::Frame; current_line=false)
    framecode = frame.framecode
    meth = framecode.scope
    @assert meth isa Method

    argnames = framecode.src.slotnames[2:meth.nargs]
    spectypes = Any[Any for i=1:length(argnames)]

    is_kw = false
    if frame.caller !== nothing
        is_kw = occursin("#kw##", string(frame.caller.framecode.scope))
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
    print(io, methname,'(')
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
    line = current_line ? JuliaInterpreter.linenumber(frame) : meth.line
    path = string(_print_full_path[] ? meth.file : basename(String(meth.file)), ":", line)
    path = CodeTracking.replace_buildbot_stdlibpath(String(path))
    print(io, ") at ", path)
end
