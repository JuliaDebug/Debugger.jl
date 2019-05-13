function locinfo(frame::Frame)
    if frame.framecode.scope isa Method
        meth = frame.framecode.scope
        ret = JuliaInterpreter.whereis(meth)
        ret === nothing && return nothing
        deffile, _ = ret
        ret = JuliaInterpreter.whereis(frame)
        ret === nothing && return nothing
        current_file, current_line = ret
        local body, defline
        try # https://github.com/timholy/CodeTracking.jl/issues/31
            body, defline = CodeTracking.definition(String, meth)
        catch
            return nothing
        end
        if deffile != current_file || defline > current_line
            isfile(current_file) || return nothing
            body = read(current_file, String)
            defline = 0 # We are not sure where the context start in cases like these, could be improved?
        end
        return defline, current_line, body
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
    print(io, meth.name,'(')
    first = true
    for (argname, argT) in zip(argnames, spectypes)
        first || print(io, ", ")
        first = false
        print(io, argname)
        !(argT === Any) && print(io, "::", argT)
    end
    line = current_line ? JuliaInterpreter.linenumber(frame) : meth.line
    path = string(_print_full_path[] ? meth.file : basename(String(meth.file)), ":", line)
    path = CodeTracking.replace_buildbot_stdlibpath(String(path))
    print(io, ") at ", path)
end