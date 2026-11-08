"""
    PureFont

A dependency-free, pure-Julia reader for OpenType / TrueType fonts (`cmap`, `head`, `hhea`, `hmtx`, `maxp`,
`OS/2`, `name`, `loca`/`glyf` including simple composite glyphs, and `CFF ` with a Type 2 charstring interpreter)
and an anti-aliased scanline rasterizer with non-zero winding.

It is written to compile with WasmCodegen (no `ccall`, no mmap, no `Dict{Symbol,Any}`, concrete field types) and
to reproduce what FreeType (via FreeTypeAbstraction.jl) reports for `FT_LOAD_NO_SCALE` metrics and what it renders
for `FT_LOAD_RENDER` bitmaps at a given pixel size, as Makie's texture atlas uses them.

Not implemented: CFF2, GPOS/`kern`/GSUB, hinting, `seac`, TrueType composite point matching, cmap formats other
than 4, 6 and 12.
"""
module PureFont

include("bytes.jl")
include("outline.jl")
include("cff.jl")
include("sfnt.jl")
include("glyf.jl")
include("raster.jl")

end
