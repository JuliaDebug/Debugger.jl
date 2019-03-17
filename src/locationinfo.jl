struct FileLocInfo
    filepath::String
    line::Int
    # 0 if unknown
    column::Int
    # The line at which the current context starts, 0 if unknown
    defline::Int
end

struct BufferLocInfo
    data::String
    line::Int
    # 0 if unknown
    column::Int
    defline::Int
end

function loc_for_fname(file::String, line::Integer, defline::Integer)
    if startswith(file, "REPL[")
        hist_idx = parse(Int,string(file)[6:end-1])
        isdefined(Base, :active_repl) || return nothing, ""
        hp = Base.active_repl.interface.modes[1].hist
        return BufferLocInfo(hp.history[hp.start_idx+hist_idx], line, 0, defline)
    else
        for path in SEARCH_PATH
            fullpath = joinpath(path,string(file))
            if isfile(fullpath)
                return FileLocInfo(fullpath, line, 0, defline)
            end
        end
    end
    return nothing
end

function locinfo(frame::Frame)
    if frame.framecode.scope isa Method
        meth = frame.framecode.scope
        def_file, def_line = JuliaInterpreter.whereis(meth)
        current_file, current_line = JuliaInterpreter.whereis(frame)
        if def_file != current_file || def_line > current_line
            def_line = 0 # We are not sure where the context start in cases like these, could be improved?
        end
        return loc_for_fname(current_file, current_line, def_line)
    else
        println("not yet implemented")
    end
end

# Used for the tests
const _print_full_path = Ref(true)

function locdesc(frame::Frame)
    sprint() do io
        if frame.framecode.scope isa Method
            locdesc(io, frame.framecode)
        else
            println(io, "not yet implemented")
        end
    end
end

function locdesc(io, framecode::FrameCode)
    meth = framecode.scope
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
    path = _print_full_path[] ? meth.file : string(basename(String(meth.file)), ":", meth.line)
    path = CodeTracking.replace_buildbot_stdlibpath(String(path))
    print(io, ") at ", path)
end