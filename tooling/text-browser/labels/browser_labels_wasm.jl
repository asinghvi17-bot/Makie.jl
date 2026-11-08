# Option C in Wasm: the two measurements of BrowserLabels (`text_width`, `font_metrics`) as host calls, instead of the table the native
# program reads. Wasm only (overlays). Same host import as browser_glyphs.jl (wasm_host.text_start/text_finish, jobs `measure` and
# `font`); needs `Config(host_extensions = [:julia_io], import_libraries = ["wasm_host"])`.
module BrowserLabelsWasm
using WasmCodegen, Makie
using ..BrowserLabels
using ..BrowserLabels: TableMetrics, FontMetrics
const WASM = WasmCodegen.Runtime.WASM_METHODS
const Staging = WasmCodegen.Runtime.Staging
const Host = WasmCodegen.Runtime.Host

@noinline host_error(what) = error(string("text host: ", what))

# (the same job runner as browser_glyphs.jl: start, wait on the julia_io handle, read the response, close)
function host_job(req::String)::Vector{UInt8}
    h = Staging.with_scope() do
        n = sizeof(req)
        off = Staging.alloc_data(n; align = 1)
        Staging.copy_to_linear!(off, req, 1, n)
        ccall((:text_start, "wasm_host"), Int32, (UInt32, UInt32), off, UInt32(n))
    end
    h > 0 || host_error("the host starts no text jobs (is its adapter installed?)")
    try
        Host.await_handle(h)
        len, buf = finish(h, Int(Staging.CHUNK) ÷ 4)
        len > 0 || host_error("no response, or one larger than the buffer")
        return buf
    finally
        Host.close(h)
    end
end
function finish(h::Int32, cap::Int)::Tuple{Int32, Vector{UInt8}}
    return Staging.with_scope() do
        res = Staging.alloc_data(cap; align = 1)
        len = ccall((:text_finish, "wasm_host"), Int32, (Int32, UInt32, UInt32), h, res, UInt32(cap))
        len <= 0 && return (len, UInt8[])
        buf = Vector{UInt8}(undef, len)
        Staging.copy_from_linear!(buf, 1, res, Int(len))
        return (len, buf)
    end
end
i32(b::Vector{UInt8}, i::Int) = (UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24) % Int32

function checked(b::Vector{UInt8})
    (length(b) >= 8 && i32(b, 1) == 1) || host_error("a malformed response")
    i32(b, 5) == 0 || host_error(string("the host failed: ", String(b[45:end])))
    return b
end

split_key(key::String) = (i = findfirst('|', key)::Int; (String(key[1:i - 1]), String(key[i + 1:end])))

Base.Experimental.@overlay WASM function BrowserLabels.text_width(m::TableMetrics, font::Makie.NativeFont, px::Float32, s::AbstractString)::Float32
    key = BrowserLabels.fontkey(font)
    k = (key, px, String(s))
    w = get(m.widths, k, nothing)
    w === nothing || return w
    style, family = split_key(key)
    esc = replace(String(s), "\\" => "\\\\", "\n" => "\\n")
    b = checked(host_job(string("wasm-text 1\nmeasure\n", style, "\n", family, "\n", px, "\n", esc)))
    w = Float32(i32(b, 9)) / 1000.0f0
    m.widths[k] = w
    return w
end

Base.Experimental.@overlay WASM function BrowserLabels.font_metrics(m::TableMetrics, font::Makie.NativeFont)::FontMetrics
    key = BrowserLabels.fontkey(font)
    fm = get(m.fonts, key, nothing)
    fm === nothing || return fm
    style, family = split_key(key)
    b = checked(host_job(string("wasm-text 1\nfont\n", style, "\n", family)))
    fm = FontMetrics(Float32(i32(b, 9)) / 1.0f6, Float32(i32(b, 13)) / 1.0f6, Float32(i32(b, 17)) / 1.0f6)
    m.fonts[key] = fm
    return fm
end

# (text.jl:447-449) whether a handler claims a block is `which` on the method table: not in Wasm. This handler claims Strings.
Base.Experimental.@overlay WASM Makie.handler_claims(::BrowserLabels.Handler, ::String) = true
Base.Experimental.@overlay WASM Makie.handler_claims(::BrowserLabels.Handler, @nospecialize(x)) = false

end # BrowserLabelsWasm
