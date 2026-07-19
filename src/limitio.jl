# Adapted from the REPL stdlib (MIT license: https://julialang.org/license)

mutable struct LimitIO{IO_t <: IO} <: IO
    const io::IO_t
    const maxbytes::Int
    n::Int # bytes written so far
end
LimitIO(io::IO, maxbytes) = LimitIO(io, maxbytes, 0)

struct LimitIOException <: Exception
    maxbytes::Int
end

function Base.showerror(io::IO, e::LimitIOException)
    print(io, "$LimitIOException: aborted printing after attempting to print more than $(Base.format_bytes(e.maxbytes)) within a `LimitIO`.")
end

Base.displaysize(io::LimitIO) = displaysize(io.io)

function Base.write(io::LimitIO, v::UInt8)
    io.n > io.maxbytes && throw(LimitIOException(io.maxbytes))
    n_bytes = write(io.io, v)
    io.n += n_bytes
    return n_bytes
end

# Semantically, we only need to override `Base.write`, but we also
# override `unsafe_write` for performance.
function Base.unsafe_write(limiter::LimitIO, p::Ptr{UInt8}, nb::UInt)
    # already exceeded? throw
    limiter.n > limiter.maxbytes && throw(LimitIOException(limiter.maxbytes))
    remaining = limiter.maxbytes - limiter.n # >= 0

    # Not enough bytes left; we will print up to the limit, then throw
    if remaining < nb
        if remaining > 0
            Base.unsafe_write(limiter.io, p, remaining)
        end
        throw(LimitIOException(limiter.maxbytes))
    end

    # We won't hit the limit so we'll write the full `nb` bytes
    bytes_written = Base.unsafe_write(limiter.io, p, nb)::Union{Int,UInt}
    limiter.n += bytes_written
    return bytes_written
end
