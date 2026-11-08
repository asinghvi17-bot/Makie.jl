# The sfnt container: table directory, `head`, `hhea`, `hmtx`, `maxp`, `OS/2`, `name`, `cmap`.

"A parsed font. Immutable and made of concrete types, so one can be a compile-time constant."
struct Font
    data::Vector{UInt8}
    is_cff::Bool
    units_per_em::Int
    ascender::Int          # hhea (OS/2 typographic values if hhea has none), as FreeType's face->ascender
    descender::Int
    height::Int            # ascender - descender + line gap
    typo_ascender::Int
    typo_descender::Int
    has_os2::Bool
    num_glyphs::Int
    num_hmetrics::Int
    hmtx::Int
    loca::Int
    loca_long::Bool
    glyf::Int
    cmap::Int              # offset of the chosen cmap subtable (0: none)
    cmap_format::Int
    family_name::String
    style_name::String
    cff::CFFData
end

"Offset of table `t` (a 4-character string) in `d`, or 0 if absent."
function find_table(d::Vector{UInt8}, t::UInt32)
    n = Int(u16(d, 4))
    for i in 0:n - 1
        o = 12 + 16i
        tag(d, o) == t && return Int(u32(d, o + 8))
    end
    return 0
end

function decode_name(d::Vector{UInt8}, o::Int, len::Int, utf16::Bool)
    chars = Char[]
    if utf16
        for i in 0:2:len - 2
            push!(chars, Char(u16(d, o + i)))
        end
    else
        for i in 0:len - 1
            push!(chars, Char(d[o + i + 1]))
        end
    end
    return String(chars)
end

"The name with ID `id` from the `name` table (Windows or Unicode platform preferred), or \"\"."
function get_name(d::Vector{UInt8}, name::Int, id::Int)
    name == 0 && return ""
    count = Int(u16(d, name + 2)); strings = name + Int(u16(d, name + 4))
    best = ""
    for i in 0:count - 1
        r = name + 6 + 12i
        Int(u16(d, r + 6)) == id || continue
        plat = Int(u16(d, r)); len = Int(u16(d, r + 8)); off = strings + Int(u16(d, r + 10))
        if plat == 3 || plat == 0
            return decode_name(d, off, len, true)
        elseif plat == 1 && isempty(best)
            best = decode_name(d, off, len, false)
        end
    end
    return best
end

function select_cmap(d::Vector{UInt8}, cmap::Int)
    cmap == 0 && return (0, 0)
    best = 0; best_score = 0; fmt = 0
    for i in 0:Int(u16(d, cmap + 2)) - 1
        r = cmap + 4 + 8i
        plat = Int(u16(d, r)); enc = Int(u16(d, r + 2)); off = cmap + Int(u32(d, r + 4))
        f = Int(u16(d, off))
        (f == 4 || f == 6 || f == 12) || continue
        score = (plat == 3 && enc == 10) || (plat == 0 && (enc == 4 || enc == 6)) ? 4 :
            (plat == 3 && enc == 1) ? 3 : plat == 0 ? 2 : 0
        if score > best_score
            best = off; best_score = score; fmt = f
        end
    end
    return (best, fmt)
end

function Font(data::Vector{UInt8})
    t = tag(data, 0)
    (t == 0x00010000 || t == tagval("OTTO") || t == tagval("true")) || error("PureFont: not a single-font sfnt (TTC and WOFF are not supported)")
    head = find_table(data, tagval("head")); hhea = find_table(data, tagval("hhea"))
    maxp = find_table(data, tagval("maxp")); hmtx = find_table(data, tagval("hmtx"))
    (head == 0 || hhea == 0 || maxp == 0 || hmtx == 0) && error("PureFont: missing head/hhea/maxp/hmtx")
    upem = Int(u16(data, head + 18))
    loca_long = i16(data, head + 50) != 0
    asc = Int(i16(data, hhea + 4)); desc = Int(i16(data, hhea + 6)); gap = Int(i16(data, hhea + 8))
    nh = Int(u16(data, hhea + 34))
    ng = Int(u16(data, maxp + 4))
    os2 = find_table(data, tagval("OS/2"))
    has_os2 = os2 != 0 && u16(data, os2) != 0xffff
    tasc = tdesc = 0
    if os2 != 0
        tasc = Int(i16(data, os2 + 68)); tdesc = Int(i16(data, os2 + 70))
        if asc == 0 && desc == 0                  # (as FreeType: fall back to OS/2)
            asc = tasc; desc = tdesc; gap = Int(i16(data, os2 + 72))
        end
    end
    cffoff = find_table(data, tagval("CFF "))
    is_cff = cffoff != 0
    cff = is_cff ? parse_cff(data, cffoff) : CFFData()
    cmap, fmt = select_cmap(data, find_table(data, tagval("cmap")))
    name = find_table(data, tagval("name"))
    fam = get_name(data, name, 16); isempty(fam) && (fam = get_name(data, name, 1))
    sty = get_name(data, name, 17); isempty(sty) && (sty = get_name(data, name, 2))
    return Font(data, is_cff, upem, asc, desc, asc - desc + gap, tasc, tdesc, has_os2, ng, nh, hmtx,
                find_table(data, tagval("loca")), loca_long, find_table(data, tagval("glyf")), cmap, fmt, fam, sty, cff)
end
Font(path::AbstractString) = Font(read(path))

Base.show(io::IO, f::Font) = print(io, "PureFont.Font(", f.family_name, ", ", f.style_name, "; ", f.num_glyphs, " glyphs, ",
                                  f.is_cff ? "CFF" : "glyf", ")")

# ---- cmap ----
"Glyph index (0-based; 0 is `.notdef`) of code point `cp`."
function glyph_index(f::Font, cp::UInt32)
    d = f.data; o = f.cmap
    o == 0 && return 0
    if f.cmap_format == 4
        cp > 0xffff && return 0
        segx2 = Int(u16(d, o + 6)); n = segx2 >> 1
        ends = o + 14; starts = o + 16 + segx2; deltas = o + 16 + 2segx2; ranges = o + 16 + 3segx2
        lo = 0; hi = n - 1
        while lo < hi                        # first segment with endCode >= cp
            mid = (lo + hi) >> 1
            Int(u16(d, ends + 2mid)) >= cp ? (hi = mid) : (lo = mid + 1)
        end
        (lo < n && Int(u16(d, ends + 2lo)) >= cp) || return 0
        start = Int(u16(d, starts + 2lo))
        cp < start && return 0
        delta = Int(u16(d, deltas + 2lo)); ro = Int(u16(d, ranges + 2lo))
        if ro == 0
            return (Int(cp) + delta) & 0xffff
        end
        g = Int(u16(d, ranges + 2lo + ro + 2 * (Int(cp) - start)))
        return g == 0 ? 0 : (g + delta) & 0xffff
    elseif f.cmap_format == 12
        n = Int(u32(d, o + 12)); lo = 0; hi = n - 1
        while lo <= hi
            mid = (lo + hi) >> 1
            g = o + 16 + 12mid
            if cp < u32(d, g)
                hi = mid - 1
            elseif cp > u32(d, g + 4)
                lo = mid + 1
            else
                return Int(u32(d, g + 8)) + Int(cp - u32(d, g))
            end
        end
        return 0
    else   # format 6
        first = Int(u16(d, o + 6)); cnt = Int(u16(d, o + 8))
        i = Int(cp) - first
        return 0 <= i < cnt ? Int(u16(d, o + 10 + 2i)) : 0
    end
end
glyph_index(f::Font, c::Char) = glyph_index(f, UInt32(c))

# ---- hmtx ----
function hadvance(f::Font, gid::Int)
    i = min(gid, f.num_hmetrics - 1)
    return Int(u16(f.data, f.hmtx + 4i))
end
function left_side_bearing(f::Font, gid::Int)
    gid < f.num_hmetrics && return Int(i16(f.data, f.hmtx + 4gid + 2))
    return Int(i16(f.data, f.hmtx + 4f.num_hmetrics + 2(gid - f.num_hmetrics)))
end

"Append the outline of glyph `gid` in font units to `out` (cleared first)."
function glyph_outline!(out::Outline, f::Font, gid::Int)
    empty!(out)
    if f.is_cff
        cff_outline!(out, f.data, f.cff, gid)
    else
        glyf_outline!(out, f, gid, 0)
        # (TrueType: the glyph is placed so that its header xMin sits at the `hmtx` left side bearing)
        s, e = glyf_range(f, gid)
        if e > s
            shift = left_side_bearing(f, gid) - Int(i16(f.data, s + 2))
            shift == 0 || (out.x .+= Float32(shift))
        end
    end
    return out
end

"""
Glyph metrics in font units, as FreeType reports them for `FT_LOAD_NO_SCALE` (the values FreeTypeAbstraction's
`get_extent` divides by `units_per_EM`).
"""
struct GlyphMetrics
    width::Int
    height::Int
    hori_bearing_x::Int
    hori_bearing_y::Int
    hori_advance::Int
    vert_bearing_x::Int
    vert_bearing_y::Int
    vert_advance::Int
end

function glyph_metrics(f::Font, gid::Int, out::Outline = Outline())
    glyph_outline!(out, f, gid)
    # (FreeType measures the control box of the loaded outline, for glyf as for CFF, not the glyf header's box)
    (x0, y0, x1, y1) = cbox(out)
    xmin = round(Int, x0); ymin = round(Int, y0); xmax = round(Int, x1); ymax = round(Int, y1)
    adv = hadvance(f, gid)
    # (no vmtx: FreeType derives the vertical metrics from OS/2 typographic values, else from hhea)
    vadv = f.has_os2 ? f.typo_ascender - f.typo_descender : f.ascender - f.descender
    # (fonts without vmtx: FreeType's CFF driver reports 0 vertical bearings, its TrueType driver centres the glyph
    # on the advance box, vertically on the advance height)
    vbx = f.is_cff ? 0 : xmin - adv ÷ 2
    vby = f.is_cff ? 0 : (vadv - (ymax - ymin)) ÷ 2
    return GlyphMetrics(xmax - xmin, ymax - ymin, xmin, ymax, adv, vbx, vby, vadv)
end
