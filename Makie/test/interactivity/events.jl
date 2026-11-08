using Makie: MouseButtonEvent, KeyEvent, Figure, Textbox
using Makie: Not, And, Or
using InteractiveUtils

# rudimentary equality for tests
Base.:(==)(l::Exclusively, r::Exclusively) = l.x == r.x
Base.:(==)(l::Not, r::Not) = l.x == r.x
Base.:(==)(l::And, r::And) = l.left == r.left && l.right == r.right
Base.:(==)(l::Or, r::Or) = l.left == r.left && l.right == r.right

function Base.isapprox(a::Rect{N, T}, b::Rect{N, T}; kwargs...) where {N, T}
    return isapprox(minimum(a), minimum(b); kwargs...) &&
        isapprox(widths(a), widths(b); kwargs...)
end

@testset "Mouse and Keyboard state" begin
    events = Makie.Events()
    @test isempty(events.mousebuttonstate)
    @test isempty(events.keyboardstate)

    events.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.press)
    events.keyboardbutton[] = KeyEvent(Keyboard.a, Keyboard.press)
    @test events.mousebuttonstate == Set([Mouse.left])
    @test events.keyboardstate == Set([Keyboard.a])

    events.mousebutton[] = MouseButtonEvent(Mouse.right, Mouse.press)
    events.keyboardbutton[] = KeyEvent(Keyboard.b, Keyboard.press)
    @test events.mousebuttonstate == Set([Mouse.left, Mouse.right])
    @test events.keyboardstate == Set([Keyboard.a, Keyboard.b])

    events.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.release)
    events.keyboardbutton[] = KeyEvent(Keyboard.a, Keyboard.release)
    @test events.mousebuttonstate == Set([Mouse.right])
    @test events.keyboardstate == Set([Keyboard.b])

    events.mousebutton[] = MouseButtonEvent(Mouse.right, Mouse.release)
    events.keyboardbutton[] = KeyEvent(Keyboard.b, Keyboard.release)
    @test isempty(events.mousebuttonstate)
    @test isempty(events.keyboardstate)
end

@testset "ispressed" begin
    events = Makie.Events()
    @test isempty(events.mousebuttonstate)
    @test isempty(events.keyboardstate)

    events.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.press)
    events.keyboardbutton[] = KeyEvent(Keyboard.a, Keyboard.press)

    # Buttons
    @test ispressed(events, Keyboard.a)
    @test !ispressed(events, Keyboard.b)
    @test ispressed(events, Mouse.left)
    @test !ispressed(events, Mouse.right)

    # Collections
    @test ispressed(events, (Keyboard.a,))
    @test ispressed(events, [Keyboard.a])
    @test ispressed(events, Set((Keyboard.a,)))

    @test !ispressed(events, (Keyboard.a, Keyboard.b))
    @test !ispressed(events, [Keyboard.a, Keyboard.b])
    @test !ispressed(events, Set((Keyboard.a, Keyboard.b)))

    @test ispressed(events, (Keyboard.a, Mouse.left))
    @test ispressed(events, [Keyboard.a, Mouse.left])
    @test ispressed(events, Set((Keyboard.a, Mouse.left)))

    # Boolean
    @test ispressed(events, Keyboard.a & Mouse.left)
    @test !ispressed(events, Keyboard.a & Mouse.right)
    @test ispressed(events, Keyboard.a & !Mouse.right)
    @test !ispressed(events, !Keyboard.a & Mouse.left)

    @test ispressed(events, Keyboard.a | Mouse.left)
    @test ispressed(events, Keyboard.a | Mouse.right)
    @test !ispressed(events, Keyboard.b | Mouse.right)
    @test ispressed(events, Keyboard.b | !Mouse.right)

    # Exclusively
    @test !ispressed(events, Exclusively(Keyboard.a))
    @test !ispressed(events, Exclusively(Mouse.left))

    @test ispressed(events, Exclusively((Keyboard.a, Mouse.left)))
    @test ispressed(events, Exclusively([Keyboard.a, Mouse.left]))
    @test ispressed(events, Exclusively(Set((Keyboard.a, Mouse.left))))

    @test Exclusively(Keyboard.a & Mouse.left) == Exclusively((Keyboard.a, Mouse.left))
    @test ispressed(events, Exclusively(Keyboard.a & Mouse.left))
    @test Exclusively(Keyboard.a | Mouse.left) == Makie.Or(Exclusively(Keyboard.a), Exclusively(Mouse.left))
    @test !ispressed(events, Exclusively(Keyboard.a | Mouse.left))

    expr = Mouse.left & (Keyboard.a | (Keyboard.a & Keyboard.b))
    lowered = Or(
        Exclusively((Mouse.left, Keyboard.a)),
        Exclusively((Mouse.left, Keyboard.a, Keyboard.b))
    )
    @test ispressed(events, expr)
    @test Exclusively(expr) == lowered
    @test ispressed(events, Exclusively(expr))

    events.keyboardbutton[] = KeyEvent(Keyboard.b, Keyboard.press)
    @test ispressed(events, expr)
    @test ispressed(events, Exclusively(expr))

    events.keyboardbutton[] = KeyEvent(Keyboard.c, Keyboard.press)
    @test ispressed(events, expr)
    @test !ispressed(events, Exclusively(expr))

    events.keyboardbutton[] = KeyEvent(Keyboard.a, Keyboard.release)
    @test !ispressed(events, expr)
    @test !ispressed(events, Exclusively(expr))

    # Bools
    @test ispressed(events, true)
    @test !ispressed(events, false)

    @test Exclusively(true) == true
    @test Exclusively(false) == false

    for x in (Keyboard.a, Mouse.left)
        @test true & x == x
        @test x & true == x
        @test false & x == false
        @test x & false == false

        @test true | x == true
        @test x | true == true
        @test false | x == x
        @test x | false == x
    end
end

@testset "ispressed on wide button types" begin
    scene = Scene()
    e = events(scene)
    e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.press)
    e.keyboardbutton[] = KeyEvent(Keyboard.a, Keyboard.press)

    # a parent other than Events, and values read from containers with a wide element type
    specs = Any[
        true, false, Keyboard.a, Keyboard.b, Mouse.left, Mouse.right,
        (Keyboard.a, Mouse.left), [Keyboard.a, Mouse.left], Set((Keyboard.a, Mouse.left)), (Keyboard.a, Mouse.right),
        Keyboard.a & Mouse.left, Keyboard.a | Mouse.right, !Keyboard.b, Exclusively((Keyboard.a, Mouse.left)),
        Set([Keyboard.a]), Set{Any}([Keyboard.a, Mouse.right]), Set{Union{Keyboard.Button, Mouse.Button}}([Keyboard.a, Mouse.left]),
        Exclusively(Keyboard.a), [Keyboard.a & Mouse.left, Keyboard.b | Mouse.left], (Keyboard.a, !Keyboard.b, true),
    ]
    expected = [
        true, false, true, false, true, false, true, true, true, false, true, true, true, true,
        true, false, true, false, true, true,
    ]
    for (spec, exp) in zip(specs, expected)
        @test ispressed(scene, spec) == exp
        @test ispressed(e, spec) == exp
        @test ispressed(scene, Ref{Makie.IsPressedInputType}(spec)[]) == exp
    end

    # waspressed counts as pressed, also through operators and collections
    @test ispressed(scene, Keyboard.b, Keyboard.b)
    @test !ispressed(scene, Keyboard.b, Keyboard.c)
    @test ispressed(scene, (Keyboard.a, Keyboard.b), Keyboard.b)
    @test ispressed(scene, Keyboard.a & Keyboard.b, Keyboard.b)
    @test !ispressed(scene, Exclusively((Keyboard.a, Mouse.left)), Keyboard.b)
    @test ispressed(scene, Exclusively((Keyboard.a, Mouse.left)), Keyboard.a)
    @test ispressed(scene, Exclusively((Keyboard.a, Mouse.left, Keyboard.b)), Keyboard.b)
    @test !ispressed(scene, Exclusively((Keyboard.a, Mouse.left, Mouse.right)), Keyboard.b)

    # button types that are not supported are still an error
    @test_throws ArgumentError ispressed(scene, :a)

    # A call with a Union (`IsPressedInputType`) or `Any` typed button (attributes, interaction fields) has to match a
    # single method. Type inference gives up on a call with more than a few candidate methods, which makes it a
    # dynamic dispatch that can't be compiled ahead of time (juliac --trim).
    for T in (Makie.IsPressedInputType, Any)
        @test length(methods(ispressed, Tuple{Scene, T})) == 1
        @test length(methods(ispressed, Tuple{Scene, T, Union{Nothing, Mouse.Button, Keyboard.Button}})) == 1
    end
end

@testset "copy_paste" begin
    # Hack to get clipboard() working without much setup
    @eval InteractiveUtils begin
        const CLIP = Ref{String}()
        clipboard(str::String) = (CLIP[] = str)
        clipboard() = CLIP[]
    end

    f = Figure(size = (640, 480))
    tb = Textbox(f[1, 1], placeholder = "Copy/paste into me")
    e = events(f.scene)

    # Initial state
    @test !tb.focused[]
    @test tb.stored_string[] === nothing

    # Select textbox
    e.mouseposition[] = (320, 240)
    e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.press)
    e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.release)
    @test tb.focused[]

    # Fill clipboard with a string
    clipboard("test string")

    # Trigger left ctrl+v
    e.keyboardbutton[] = KeyEvent(Keyboard.left_control, Keyboard.press)
    e.keyboardbutton[] = KeyEvent(Keyboard.v, Keyboard.press)
    e.keyboardbutton[] = KeyEvent(Keyboard.v, Keyboard.release)
    e.keyboardbutton[] = KeyEvent(Keyboard.left_control, Keyboard.release)
    e.keyboardbutton[] = KeyEvent(Keyboard.enter, Keyboard.press)
    e.keyboardbutton[] = KeyEvent(Keyboard.enter, Keyboard.release)

    @test tb.stored_string[] == "test string"


    # Refresh figure to test right control + v combination
    empty!(f)

    f = Figure(size = (640, 480))
    tb = Textbox(f[1, 1], placeholder = "Copy/paste into me")
    e = events(f.scene)

    # Initial state
    @test !tb.focused[]
    @test tb.stored_string[] === nothing

    # Re-select textbox
    e.mouseposition[] = (320, 240)
    e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.press)
    e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.release)
    @test tb.focused[]

    clipboard("test string2")

    # Trigger right ctrl+v
    e.keyboardbutton[] = KeyEvent(Keyboard.right_control, Keyboard.press)
    e.keyboardbutton[] = KeyEvent(Keyboard.v, Keyboard.press)
    e.keyboardbutton[] = KeyEvent(Keyboard.v, Keyboard.release)
    e.keyboardbutton[] = KeyEvent(Keyboard.right_control, Keyboard.release)
    e.keyboardbutton[] = KeyEvent(Keyboard.enter, Keyboard.press)
    e.keyboardbutton[] = KeyEvent(Keyboard.enter, Keyboard.release)

    @test tb.stored_string[] == "test string2"
end

@testset "Builtin interaction helpers" begin
    f = Figure(size = (400, 400))
    a = Axis(f[1, 1])
    e = events(f)

    @testset "select_point()" begin
        point = select_point(a)
        initial_pos = point[]

        # Initialize the position in the axis
        e.mouseposition[] = (200, 200)

        # The point should only be updated when the user releases the mouse
        e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.press)
        e.mouseposition[] = (100, 100)
        @test point[] == initial_pos
        e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.release)
        @test point[] != initial_pos
    end

    @testset "select_rectangle()" begin
        rect = select_rectangle(a)
        initial_rect = rect[]

        # Similarly to the select_point() test, we initialize the mouse position
        # and check that the rect isn't updated until the mouse is released.
        e.mouseposition[] = (200, 200)
        e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.press)
        e.mouseposition[] = (100, 100)
        @test rect[] == initial_rect
        e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.release)
        @test rect[] != initial_rect
    end
end
