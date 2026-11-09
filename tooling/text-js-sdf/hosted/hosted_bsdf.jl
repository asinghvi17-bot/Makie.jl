# B' run natively ("hosted"): the SAME source as the Wasm module (probes/browser_glyphs_sdf.jl), evaluated as ordinary methods
# instead of Wasm-only overlays, with the host's jobs answered from a table that Chromium filled (the real WasmHost adapter code
# `runTextRequest` + `browserBackend` + `sdfTile`). It gives WGLMakie, running natively, the atlas and extents the Wasm module builds,
# so a figure can be rendered and screenshotted by the real WGLMakie JS and diffed against native FreeType. (The Wasm module
# itself cannot be displayed: there is no JS<->Wasm session bridge yet, capmap blocker 4.)
#
#   HOST_TABLE=table.tsv (base64(request) TAB base64(response) per line); requests the table lacks are answered with a placeholder and
#   written to HOST_MISSING (base64(request) per line): run_hosted.sh loops with run_answer.mjs until none is missing.
#   Differences from the Wasm build, all deliberate: `host_job` is a table lookup; the `getproperty(::FTFont)` overlay is not applied
#   (native FTFont keeps its own: the host's font metrics are equal to FreeType's, 947/-218/1165, see REPORT.md section 2);
#   the other overlays (glyph_index = codepoint, get_extent, find_font_for_char, get_texture_atlas, insert_glyph!) are applied as
#   plain methods, which replaces FreeType for this process.
using Base64
const HOST_TABLE = Dict{String, Vector{UInt8}}()
const HOST_MISSING = Set{String}()
const HOST_JOBS = Ref(0)
function load_host_table!(path)
    isfile(path) || return
    for l in eachline(path)
        isempty(l) && continue
        a, b = split(l, '\t')
        HOST_TABLE[String(base64decode(a))] = base64decode(b)
    end
end
function placeholder(req::String)
    kind = split(req, '\n')[2]
    n = kind == "font" ? 5 : 11
    nbytes = kind == "sdf" ? 4 : 0       # (a 1x1 tile)
    b = zeros(UInt8, 4n + nbytes)
    b[1] = 1
    if kind == "sdf"; b[9] = 1; b[13] = 1; end
    return b
end
function HOSTED_JOB(req::String)
    HOST_JOBS[] += 1
    r = get(HOST_TABLE, req, nothing)
    r === nothing || return r
    push!(HOST_MISSING, req)
    return placeholder(req)
end
function write_missing(path)
    open(path, "w") do io
        for r in sort!(collect(HOST_MISSING))
            println(io, base64encode(r))
        end
    end
    return length(HOST_MISSING)
end

function load_bsdf_hosted(src_path)
    src = read(src_path, String)
    src = replace(src, "Base.Experimental.@overlay WASM " => "")
    # no getproperty method for FTFont (see the header)
    src = replace(src, r"function Base\.getproperty\(font::FTA\.FTFont, s::Symbol\).*?\n    return getfield\(font, s\)\nend\n"s => "")
    # host_job: the table
    src = replace(src, r"function host_job\(req::String\)::Vector\{UInt8\}.*?(?=# \(the response of the finished job)"s => "host_job(req::String)::Vector{UInt8} = Main.HOSTED_JOB(req)\n\n")
    include_string(Main, src, src_path)
    return Main.BrowserGlyphsSDF
end
