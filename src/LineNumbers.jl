module LineNumbers

export SourceFile, compute_line, LineBreaking

# Offsets are 0 based
struct SourceFile
    data::Vector{UInt8}
    offsets::Vector{UInt64}
end

function SourceFile(data::AbstractString)
    offsets = UInt64[0]
    buf = IOBuffer(data)
    line = ""
    while !eof(buf)
        line = readuntil(buf,'\n')
        !eof(buf) && push!(offsets, position(buf))
    end
    if !isempty(offsets) && !isempty(line) && line[end] == '\n'
        push!(offsets, position(buf))
    end
    SourceFile(copy(codeunits(data)), offsets)
end

function compute_line(file::SourceFile, offset::Integer)
    ind = searchsortedfirst(file.offsets, offset)
    ind <= length(file.offsets) && file.offsets[ind] == offset ? ind : ind - 1
end



end # module
