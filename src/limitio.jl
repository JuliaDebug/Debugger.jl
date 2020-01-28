mutable struct LimitIO{IO_t <: IO} <: IO
    io::IO_t
    maxbytes::Int
    n::Int # max bytes to write
end
LimitIO(io::IO, maxbytes) = LimitIO(io, maxbytes, 0) 

struct LimitIOException <: Exception end

function Base.write(io::LimitIO, v::UInt8)
    io.n > io.maxbytes && throw(LimitIOException())
    io.n += write(io.io, v)
end

