# Option C: no SDF. A `text_handler` that lays strings out with the BROWSER's metrics (`measureText`) and draws nothing into WebGL,
# and `collect_labels`, which turns every Text plot of a scene into a list of labels (string, anchor, size, color, rotation) for a
# DOM overlay or a Canvas2D layer on the page. Plain `String`s only: LaTeXString and RichText fall through to Makie's own layout
# (glyphs, FreeType), see the notes in tooling/text-browser/NOTES.md.
#
# Metrics come from a `Metrics` object: `TableMetrics` (measurements the browser made earlier, in a TSV; for native runs) or the
# wasm host import (`wasm_host.text_start` `measure` job, browser_labels_wasm.jl).
module BrowserLabels
using Makie, GeometryBasics
import FreeTypeAbstraction as FTA
using Makie: TextLayout, GlyphExtent, TextAttributes, NativeFont, Rect2f, Point3f, Vec2f, RGBAf

## metrics

struct FontMetrics
    ascender::Float32     # em fractions; descender negative; height = ascender - descender + line gap
    descender::Float32
    height::Float32
end

abstract type Metrics end

"The browser's `measureText` results, from a TSV (`F key asc desc height`, `W key size string width_px`)."
mutable struct TableMetrics <: Metrics
    fonts::Dict{String, FontMetrics}
    widths::Dict{Tuple{String, Float32, String}, Float32}     # (font key, css px, string) => width in px
    missing_fonts::Set{String}
    missing_widths::Set{Tuple{String, Float32, String}}
    fallback::Bool                                               # answer a missing entry from FreeType (pass 1), else error
end
TableMetrics(; fallback = true) = TableMetrics(Dict{String, FontMetrics}(), Dict{Tuple{String, Float32, String}, Float32}(),
                                              Set{String}(), Set{Tuple{String, Float32, String}}(), fallback)

const METRICS = Ref{Metrics}(TableMetrics())

function fontkey(font::NativeFont)
    style = font.style_name
    words = String[]
    occursin("Italic", style) && push!(words, "italic")
    occursin("Bold", style) && push!(words, "bold")
    return string(join(words, ' '), "|", font.family_name)
end

esc(s::AbstractString) = replace(s, "\\" => "\\\\", "\n" => "\\n", "\t" => "\\t")
unesc(s::AbstractString) = replace(replace(replace(s, "\\n" => "\n"), "\\t" => "\t"), "\\\\" => "\\")

function load!(m::TableMetrics, path::AbstractString)
    for l in eachline(path)
        f = split(l, '\t')
        if f[1] == "F"
            m.fonts[f[2]] = FontMetrics(parse(Float32, f[3]), parse(Float32, f[4]), parse(Float32, f[5]))
        elseif f[1] == "W"
            m.widths[(f[2], parse(Float32, f[3]), unesc(f[4]))] = parse(Float32, f[5])
        end
    end
    return m
end

"The measurements the browser still has to make: one request per line (`F key`, `W key size string`)."
function write_missing(m::TableMetrics, path::AbstractString)
    open(path, "w") do io
        for k in m.missing_fonts
            println(io, "F\t", k)
        end
        for (k, px, s) in m.missing_widths
            println(io, "W\t", k, "\t", px, "\t", esc(s))
        end
    end
    return length(m.missing_fonts) + length(m.missing_widths)
end

function font_metrics(m::TableMetrics, font::NativeFont)::FontMetrics
    k = fontkey(font)
    fm = get(m.fonts, k, nothing)
    fm === nothing || return fm
    push!(m.missing_fonts, k)
    m.fallback || error("BrowserLabels: no browser metrics for the font ", k)
    return FontMetrics(FTA.ascender(font), FTA.descender(font), font.height / font.units_per_EM)
end

"Width in CSS px of `s` set in `font` at `px` pixels, as the browser measures it (kerning and ligatures included)."
function text_width(m::TableMetrics, font::NativeFont, px::Float32, s::AbstractString)::Float32
    k = (fontkey(font), px, String(s))
    w = get(m.widths, k, nothing)
    w === nothing || return w
    push!(m.missing_widths, k)
    m.fallback || error("BrowserLabels: no browser measurement for ", k)
    return sum(c -> FTA.hadvance(FTA.get_extent(font, c)), collect(s); init = 0.0f0) * px     # (FreeType's, until the browser has measured it)
end

## the text_handler

"""
A `text_handler` that claims `String`s: layout from browser metrics, and nothing for WebGL to draw.

Makie derives the string bounding boxes that Axis protrusions, Legend, Colorbar... are laid out from out of the *per-glyph* arrays
(`raw_glyph_boundingboxes`, text.jl:836-915), not from `TextLayout.bbox`. So the layout still returns one invisible "glyph" per line:
a blank glyph (the font's space, transparent) whose advance is the browser's width of the line. Nothing visible reaches WebGL;
every string measurement downstream (alignment, `string_boundingboxes`, tick label sizes) uses the browser's numbers.
"""
struct Handler end

function Makie.layout_text(::Handler, src::String, attributes::TextAttributes)
    (; font, fontsize, lineheight, justification) = attributes
    # (an empty string is no block in Makie's layout: zero size, which Axis uses for an unset subtitle)
    isempty(src) && return Makie.layout_text(nothing, src, attributes)
    m = METRICS[]
    fs = fontsize[1]
    fm = font_metrics(m, font)
    lines = split(src, '\n')
    widths = Float32[text_width(m, font, fs, l) for l in lines]
    maxw = maximum(widths)
    lh = fm.height * lineheight * fs                   # layout_string: font.height / units_per_EM * lineheight * scale
    ybase = -(length(lines) - 1) * lh                  # (the last line's baseline; the first sits at 0)
    bottom = ybase + fm.descender * fs
    top = fm.ascender * fs
    blank = UInt64(FTA.glyph_index(font, ' '))
    n = length(lines)
    origins = [Point3f((maxw - widths[j]) * justification, -(j - 1) * lh, 0) for j in 1:n]
    extents = [GlyphExtent(Rect2f(0, 0, 0, 0), fm.ascender, fm.descender, widths[j] / fs) for j in 1:n]
    return TextLayout(
        fill(blank, n), fill(font, n), origins, extents;
        bbox = Rect2f(0, bottom, maxw, top - bottom), baseline = Float32(ybase),
        scales = fontsize, colors = RGBAf(0, 0, 0, 0), strokecolors = RGBAf(0, 0, 0, 0), strokewidths = 0.0f0,
    )
end

## the label list

struct Label
    text::String
    x::Float32            # the first baseline's left end, in window pixels, y down
    y::Float32
    size::Float32         # CSS px
    color::RGBAf
    angle::Float32        # radians, counter-clockwise as Makie has it
    family::String
    style::String
    ascender::Float32     # em fractions, for the page (CSS box = ascender + |descender|)
    descender::Float32
    width::Float32        # the browser's measurement of the line, px
end

function all_text_plots!(out::Vector{Makie.Text}, plots)
    for p in plots
        p isa Makie.Text && push!(out, p)
        all_text_plots!(out, p.plots)
    end
    return out
end
function text_plots(scene::Makie.Scene, out = Makie.Text[])
    all_text_plots!(out, scene.plots)
    foreach(c -> text_plots(c, out), scene.children)
    return out
end

rot_angle(q) = Float32(2 * atan(q[3], q[4]))      # (a rotation about z)

"The labels of every visible `String` Text plot of `scene`; `skipped`: the blocks it cannot draw (not a String, or a non-flat rotation)."
function collect_labels(scene::Makie.Scene)
    m = METRICS[]
    labels = Label[]
    skipped = String[]
    H = Float32(widths(Makie.viewport(scene)[])[2])
    for p in text_plots(scene)
        p.visible[] || continue
        strs = p.input_text[]
        blocks = p.text_blocks[]
        bboxes = p.block_bboxes[]; baselines = p.block_baselines[]
        positions = p.markerspace_positions[]
        aligns, rots, offs = p.align[], p.rotation[], p.offset[]
        fonts = p.selected_font[]
        sizes = p.fontsize[]
        colors = p.computed_color[]
        psc = Makie.parent_scene(p)
        vp = Makie.viewport(psc)[]
        for (i, str) in enumerate(strs)
            if !(str isa String)
                push!(skipped, string(typeof(str)))
                continue
            end
            font = Makie.sv_getindex(fonts, i)
            fs = Makie.to_2d_scale(Makie.sv_getindex(sizes, i))[1]
            rot = Makie.sv_getindex(rots, i)
            shift = Makie.block_alignment_shift(bboxes[i], baselines[i], Makie.sv_getindex(aligns, i))
            # (the layout frame's origin in the block's rotated frame, then the anchor: markerspace position and offset)
            anchor = Point3f(positions[i]) + Vec3f(Makie.to_ndim(Vec3f, Makie.sv_getindex(offs, i), 0))
            fm = font_metrics(m, font)
            lh = fm.height * Makie.sv_getindex(p.lineheight[], i) * fs
            lines = split(str, '\n')
            just = Float32(Makie.sv_getindex(p.resolved_justification[], i))
            ws = Float32[text_width(m, font, fs, l) for l in lines]
            maxw = maximum(ws)
            col = Makie.to_color(Makie.sv_getindex(colors, i))
            for (j, l) in enumerate(lines)
                isempty(l) && continue
                p0 = Vec3f((maxw - ws[j]) * just, -(j - 1) * lh, 0) - shift
                q = rot * p0
                x = anchor[1] + q[1] + vp.origin[1]
                y = anchor[2] + q[2] + vp.origin[2]
                push!(labels, Label(String(l), x, H - y, fs, RGBAf(col), rot_angle(rot), font.family_name,
                                    split(fontkey(font), '|')[1], fm.ascender, fm.descender, ws[j]))
            end
        end
    end
    return labels, skipped
end

jsonstr(s::AbstractString) = string('"', replace(s, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\t" => "\\t"), '"')
function labels_json(labels::Vector{Label}, size::Tuple{Real, Real})
    io = IOBuffer()
    print(io, "{\"width\":", size[1], ",\"height\":", size[2], ",\"labels\":[")
    for (i, l) in enumerate(labels)
        i > 1 && print(io, ",")
        c = l.color
        print(io, "{\"text\":", jsonstr(l.text), ",\"x\":", round(l.x; digits = 3), ",\"y\":", round(l.y; digits = 3), ",\"size\":", l.size,
              ",\"color\":[", c.r, ",", c.g, ",", c.b, ",", c.alpha, "],\"angle\":", round(l.angle; digits = 5), ",\"family\":", jsonstr(l.family),
              ",\"style\":", jsonstr(l.style), ",\"ascender\":", l.ascender, ",\"descender\":", l.descender, ",\"width\":", round(l.width; digits = 3), "}")
    end
    print(io, "]}")
    return String(take!(io))
end

end # BrowserLabels
