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
        file, def_line = JuliaInterpreter.whereis(meth)
        _, current_line = JuliaInterpreter.whereis(frame)
        return loc_for_fname(file, current_line, def_line)
    else
        println("not yet implemented")
    end
end

# Used for the tests
const _print_full_path = Ref(true)

function locdesc(frame::Frame)
    sprint() do io
        if frame.framecode.scope isa Method
            meth = frame.framecode.scope
            argnames = frame.framecode.src.slotnames[2:meth.nargs]
            spectypes = Any[Any for i=1:length(argnames)]
            print(io, meth.name,'(')
            first = true
            for (argname, argT) in zip(argnames, spectypes)
                first || print(io, ", ")
                first = false
                print(io, argname)
                !(argT === Any) && print(io, "::", argT)
            end
            print(io, ") at ", _print_full_path[] ? meth.file : basename(String(meth.file)), ":",meth.line)
        else
            println("not yet implemented")
        end
    end
end

"""
Determine the offsets in the source code to print, based on the offset of the
currently highlighted part of the code, and the start and stop line of the
entire function.
"""
function compute_source_offsets(code::String, offset::Integer, startline::Integer, stopline::Integer; file::SourceFile = SourceFile(code))
    offsetline = compute_line(file, offset)
    if offsetline - 3 > length(file.offsets) || startline > length(file.offsets)
        return -1, -1
    end
    startoffset = max(file.offsets[max(offsetline-3,1)], file.offsets[startline])
    stopoffset = lastindex(code)-1
    if offsetline + 3 < lastindex(file.offsets)
        stopoffset = min(stopoffset, file.offsets[offsetline + 3]-1)
    end
    if stopline + 1 < lastindex(file.offsets)
        stopoffset = min(stopoffset, file.offsets[stopline + 1]-1)
    end
    startoffset, stopoffset
end

function print_sourcecode(io::IO, code::String, line::Integer, defline::Integer; file::SourceFile = SourceFile(code))
    startoffset, stopoffset = compute_source_offsets(code, file.offsets[line], defline, line+3; file=file)

    if startoffset == -1
        printstyled(io, "Line out of file range (bad debug info?)", color=:bold)
        return
    end

    # Compute necessary data for line numbering
    startline = compute_line(file, startoffset)
    stopline = compute_line(file, stopoffset)
    current_line = line
    stoplinelength = length(string(stopline))

    code = split(code[(startoffset+1):(stopoffset+1)],'\n')
    lineno = startline

    if !isempty(code) && isempty(code[end])
        pop!(code)
    end

    for textline in code
        printstyled(io,
            string(lineno, " "^(stoplinelength-length(lineno)+1));
            color = lineno == current_line ? :yellow : :bold)
        println(io, textline)
        lineno += 1
    end
    println(io)
end
