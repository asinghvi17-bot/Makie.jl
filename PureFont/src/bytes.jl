# Big-endian readers over a `Vector{UInt8}`; offsets are 0-based like the tables' own offsets.
@inline u8(d::Vector{UInt8}, o::Integer) = d[o + 1]
@inline u16(d::Vector{UInt8}, o::Integer) = (UInt16(d[o + 1]) << 8) | UInt16(d[o + 2])
@inline i16(d::Vector{UInt8}, o::Integer) = reinterpret(Int16, u16(d, o))
@inline u32(d::Vector{UInt8}, o::Integer) = (UInt32(u16(d, o)) << 16) | UInt32(u16(d, o + 2))
@inline i32(d::Vector{UInt8}, o::Integer) = reinterpret(Int32, u32(d, o))
@inline tag(d::Vector{UInt8}, o::Integer) = u32(d, o)

"A table tag such as `\"CFF \"` as the UInt32 that `tag` reads."
@inline function tagval(s::String)
    v = UInt32(0)
    for i in 1:4
        v = (v << 8) | UInt32(codeunit(s, i))
    end
    return v
end
