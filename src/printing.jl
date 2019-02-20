
struct Suppressed{T}
    item::T
end
Base.show(io::IO, x::Suppressed) = print(io, "<suppressed ", x.item, '>')

function print_var(io::IO, name::Symbol, val)
    print("  | ")
    if val === nothing
        @assert false
    else
        val = something(val)
        T = typeof(val)
        try
            val = repr(val)
            if length(val) > 150
                val = Suppressed("$(length(val)) bytes of output")
            end
        catch
            val = Suppressed("printing error")
        end
        println(io, name, "::", T, " = ", val)
    end
end

print_locdesc(io::IO, frame::JuliaStackFrame) = println(io, locdesc(frame))

function print_locals(io::IO, frame::JuliaStackFrame)
    for i = 1:length(frame.locals)
        if !isa(frame.locals[i], Nothing)
            # #self# is only interesting if it has values inside of it. We already know
            # which function we're in otherwise.
            val = something(frame.locals[i])
            if frame.code.code.slotnames[i] == Symbol("#self#") && (isa(val, Type) || sizeof(val) == 0)
                continue
            end
            print_var(io, frame.code.code.slotnames[i], frame.locals[i])
        end
    end
    if frame.code.scope isa Method
        for (sym, value) in zip(sparam_syms(frame.code.scope), frame.sparams)
            print_var(io, sym, value)
        end
    end
end

function print_frame(io::IO, num::Integer, frame::JuliaStackFrame)
    print(io, "[$num] ")
    print_locdesc(io, frame)
    print_locals(io, frame)
end
