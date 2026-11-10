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

    # button types that are not supported are still an error, also inside operators and collections
    @test_throws ArgumentError ispressed(scene, :a)
    @test_throws ArgumentError ispressed(scene, (Keyboard.a, :a))
    @test_throws ArgumentError ispressed(scene, [:a])
    @test_throws ArgumentError ispressed(scene, Set([:a]))
    @test_throws ArgumentError ispressed(scene, Not(:a))
end

@testset "ispressed on collections of any element type" begin
    scene = Scene()
    e = events(scene)
    e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.press)
    e.keyboardbutton[] = KeyEvent(Keyboard.a, Keyboard.press)

    a_and_l = Keyboard.a & Mouse.left
    b_or_l = Keyboard.b | Mouse.left
    a_or_b = Keyboard.a | Keyboard.b
    not_b = !Keyboard.b
    not_a = !Keyboard.a
    b_and_l = Keyboard.b & Mouse.left

    # concrete element types that are not Vector{BooleanOperator}
    @test typeof([a_and_l]) != Vector{Makie.BooleanOperator}
    @test ispressed(scene, [a_and_l])
    @test !ispressed(scene, [a_and_l, b_and_l])
    @test ispressed(scene, [b_or_l])
    @test ispressed(scene, [not_b])
    @test !ispressed(scene, [not_a])
    @test ispressed(scene, Set([a_and_l, b_or_l]))
    @test !ispressed(scene, Set([a_and_l, b_and_l]))
    @test ispressed(scene, Makie.BooleanOperator[a_and_l, b_or_l])
    @test ispressed(scene, (a_and_l, not_b))
    @test ispressed(e, [a_and_l, a_or_b, not_b])

    # mixed unions of element types
    @test ispressed(scene, Union{Keyboard.Button, Bool}[Keyboard.a, true])
    @test !ispressed(scene, Union{Keyboard.Button, Bool}[Keyboard.a, false])
    @test ispressed(scene, Union{Keyboard.Button, Makie.BooleanOperator}[Keyboard.a, not_b])
    @test ispressed(scene, Set{Union{Mouse.Button, Makie.BooleanOperator}}([Mouse.left, a_and_l]))
    @test !ispressed(scene, Union{Keyboard.Button, Makie.BooleanOperator}[Keyboard.a, b_and_l])
    @test ispressed(scene, Any[Keyboard.a, [Mouse.left, a_and_l], (true, Set([Keyboard.a]))])
    @test !ispressed(scene, Any[Keyboard.a, [Mouse.left, b_and_l]])

    # empty collections are all-pressed, whatever their element type
    @test ispressed(scene, [])
    @test ispressed(scene, ())
    @test ispressed(scene, Set())
    @test ispressed(scene, Keyboard.Button[])
    @test ispressed(scene, Set{Mouse.Button}())
    @test ispressed(scene, Makie.And[])
    @test ispressed(scene, Set{Makie.Or}())
    @test ispressed(scene, Union{}[])
    @test ispressed(scene, Set{Union{}}())

    # waspressed also reaches elements of every kind of collection
    @test ispressed(scene, [Keyboard.b & Mouse.left], Keyboard.b)
    @test !ispressed(scene, [Keyboard.b & Mouse.left], Keyboard.c)
    @test ispressed(scene, Set([Keyboard.b | Keyboard.c]), Keyboard.b)
end

@testset "ispressed inference" begin
    # A call with a Union (`IsPressedInputType`) or `Any` typed button (attributes, interaction fields) must infer
    # as Bool and match a single method. Type inference gives up on a call with more than a few candidate methods,
    # which makes it a dynamic dispatch that can't be compiled ahead of time (juliac --trim, WasmCodegen).
    waspressed_types = (Nothing, Mouse.Button, Keyboard.Button, Union{Nothing, Mouse.Button, Keyboard.Button})
    for T in (Makie.IsPressedInputType, Any, Bool, Keyboard.Button, Mouse.Button, Makie.BooleanOperator, Set, Vector, Tuple)
        for P in (Scene, Events, Any)
            @test Base.return_types(ispressed, Tuple{P, T}) == [Bool]
            for W in waspressed_types
                @test Base.return_types(ispressed, Tuple{P, T, W}) == [Bool]
            end
        end
    end
    @test Base.return_types(ispressed, Tuple{Scene, Vector{Makie.And{Keyboard.Button, Mouse.Button}}}) == [Bool]
    @test Base.return_types(ispressed, Tuple{Scene, Set{Enum{Int32}}}) == [Bool]
    @test Base.return_types(ispressed, Tuple{Scene, Makie.And{Keyboard.Button, Mouse.Button}}) == [Bool]

    # `ispressed` is a single method, so that there is one candidate whatever the button type. This has to run before
    # the next testset adds a method for another type.
    for T in (Makie.IsPressedInputType, Any)
        @test length(methods(ispressed, Tuple{Scene, T})) == 1
        @test length(methods(ispressed, Tuple{Scene, T, Union{Nothing, Mouse.Button, Keyboard.Button}})) == 1
    end
end

struct CustomButton
    ispressed::Bool
end
Makie.ispressed(parent, b::CustomButton, waspressed = nothing) = b.ispressed

@testset "ispressed with methods for other types" begin
    scene = Scene()
    e = events(scene)
    e.keyboardbutton[] = KeyEvent(Keyboard.a, Keyboard.press)
    yes = CustomButton(true)
    no = CustomButton(false)

    @test ispressed(scene, yes)
    @test !ispressed(scene, no)
    # third party methods are used inside operators and collections as well
    @test ispressed(scene, And(Keyboard.a, yes))
    @test !ispressed(scene, And(Keyboard.a, no))
    @test ispressed(scene, Or(Keyboard.b, yes))
    @test ispressed(scene, Not(no))
    @test !ispressed(scene, Not(yes))
    @test ispressed(scene, (yes, Keyboard.a))
    @test !ispressed(scene, (yes, no))
    @test ispressed(scene, [yes, yes])
    @test !ispressed(scene, [yes, no])
    @test ispressed(scene, Set([yes]))
    @test ispressed(scene, Any[Keyboard.a, yes, [And(Keyboard.a, yes)]])
    @test ispressed(e, And(Keyboard.a, yes))
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
