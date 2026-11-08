using Test
using PureFont
# Parity tests against FreeTypeAbstraction live in test/parity.jl (they need FreeTypeAbstraction and Makie's fonts).
@testset "PureFont" begin
    @test PureFont.tagval("CFF ") == 0x43464620
end
