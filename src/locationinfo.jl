struct FileLocInfo
    filepath::String
    line::Int
    # 0 if unknown
    column::Int
    # The line at which the current context starts, 0 if unknown
    defline::Int
    # typemax(int) if unknown
    endline::Int
end

struct BufferLocInfo
    data::String
    line::Int
    # 0 if unknown
    column::Int
    defline::Int
    # typemax(int) if unknown
    endline::Int
end

function loc_for_fname(file::String, line::Integer, defline::Integer, endline::Integer)
    if startswith(file, "REPL[")
        hist_idx = parse(Int,string(file)[6:end-1])
        isdefined(Base, :active_repl) || return nothing, ""
        hp = Base.active_repl.interface.modes[1].hist
        return BufferLocInfo(hp.history[hp.start_idx+hist_idx], line, 0, defline, endline)
    else
        for path in SEARCH_PATH
            fullpath = joinpath(path,string(file))
            if isfile(fullpath)
                return FileLocInfo(fullpath, line, 0, defline, endline)
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
        n_stmts = length(frame.framedata.ssavalues)
        total_lines = JuliaInterpreter.linenumber(frame, 1n_stmts) - def_line + 1
        # We currently cannot see a difference between f(x) = x and
        # function f(x)
        #     x
        # end
        # If we could, we would do the += 1 below only in the second case
        # This means that we now miss printing the end for cases like the second
        # (one line bodies)
        total_lines == 1 || (total_lines += 1)
        end_line = def_line + total_lines - 1
        if def_file != current_file || def_line > current_line
            def_line = 0 # We are not sure where the context start in cases like these, could be improved?
            end_line = typemax(Int)
        end
        return loc_for_fname(current_file, current_line, def_line, end_line)
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