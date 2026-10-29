import SwiftUI

/// The shaders in Shaders.metal, as SwiftUI effects.
///
/// Every shader's `time` is seconds on one clock, `Date.timeIntervalSinceReferenceDate` as
/// `Motion.seconds(_:)` reads it from a timeline, and `WaterImpact.start` and `WaterStain.start` are on
/// that same clock. Before it reaches the GPU the clock is folded into a `clockCycle` of 1000 s (see
/// `wrapped(_:)`), so a `Float` keeps millisecond precision however long the app has been running;
/// starts are folded with it (`wrapped(start:time:)`), so an age stays right across the fold.
enum ShaderEffects {
    /// Paints the view's opaque pixels in one colour.
    static func tint(_ color: Color) -> Shader {
        ShaderLibrary.default.probeTint(.color(color))
    }

    /// Living water over the board's gradient fill (`oceanWater`): slow swell, caustic light and glints,
    /// modulating the colour beneath by about ±4 % when calm and ±9 % when rough, never over the
    /// luminance cap. `size` is the water's size in points; `seaState` runs from 0 (calm) to 1 (rough).
    static func water(time: TimeInterval, size: CGSize, seaState: Double) -> Shader {
        ShaderLibrary.default.oceanWater(
            .float(Float(wrapped(time))),
            .float2(size),
            .float(Float(min(max(seaState, 0), 1)))
        )
    }

    /// Rings bending the water where shells have just landed (`rippleDistort`), for `distortionEffect`
    /// with a `maxSampleOffset` of `cell * 0.2` on each axis. Positions are in the shaded view's own
    /// coordinates. The first four impacts are used, so pass the live ones, newest first.
    static func ripples(time: TimeInterval, size: CGSize, cell: CGFloat, impacts: [WaterImpact]) -> Shader {
        let slots = padded(impacts.prefix(4).map { $0.argument(time: time) })
        return ShaderLibrary.default.rippleDistort(
            .float(Float(wrapped(time))),
            .float2(size),
            .float(Float(cell)),
            slots[0],
            slots[1],
            slots[2],
            slots[3]
        )
    }

    /// Oil darkening the water where ships burn and foam where shells splashed (`stainWash`). Positions
    /// are in the shaded view's own coordinates. The first four stains are used.
    static func stains(time: TimeInterval, cell: CGFloat, stains: [WaterStain]) -> Shader {
        let slots = padded(stains.prefix(4).map { $0.argument(time: time) })
        return ShaderLibrary.default.stainWash(
            .float(Float(wrapped(time))),
            .float(Float(cell)),
            slots[0],
            slots[1],
            slots[2],
            slots[3]
        )
    }

    // MARK: The shader clock

    /// The length of the cycle the shader clock is folded into, in seconds.
    static let clockCycle: TimeInterval = 1000

    /// `seconds` folded into the shader's cycle: at least 0 and less than `clockCycle`.
    static func wrapped(_ seconds: TimeInterval) -> TimeInterval {
        let remainder = seconds.truncatingRemainder(dividingBy: clockCycle)
        return remainder < 0 ? remainder + clockCycle : remainder
    }

    /// `start` folded like `wrapped(_:)`, but kept before the folded `time` when the clock has folded
    /// since, so `time - start` is still the age.
    static func wrapped(start: TimeInterval, time: TimeInterval) -> TimeInterval {
        let folded = wrapped(start)
        return folded - wrapped(time) > clockCycle / 2 ? folded - clockCycle : folded
    }

    /// `arguments` made up to the four slots the ripple and stain shaders take, with empty ones.
    private static func padded(_ arguments: [Shader.Argument]) -> [Shader.Argument] {
        var slots = arguments
        while slots.count < 4 {
            slots.append(.float4(Float(0), Float(0), Float(0), Float(0)))
        }
        return slots
    }
}

/// A ripple on the water where a shell has landed: where it struck, when, and what it struck.
///
/// `x` and `y` are points in the coordinate space of the view that shades the water: `BoardView` takes
/// them in the board's space (what `BoardGeometry.center(of:)` gives) and `WaterView` moves them into
/// the water's. `start` is `Date.timeIntervalSinceReferenceDate` when the shell landed, the clock
/// `Motion.seconds(_:)` reads from a timeline; the ring plays for `life` seconds after it.
struct WaterImpact: Equatable, Sendable {
    /// What the shell struck. The raw values are the `kind` the shader reads; 0 is no impact.
    enum Kind: Int, Equatable, Sendable {
        /// Open water: a soft ring.
        case splash = 1
        /// A hull: a stronger, faster ring.
        case hit = 2

        /// How fast the ring travels, in cells a second. Mirrors `rippleShift` in Shaders.metal.
        var ringSpeed: Double {
            self == .hit ? 2.2 : 1.6
        }
    }

    var x: CGFloat
    var y: CGFloat
    var start: TimeInterval
    var kind: Kind

    /// How long a ring plays, in seconds. Mirrors `rippleShift` in Shaders.metal.
    static let life: TimeInterval = 1.3
    /// The ring's radius when it is born, in cells. Mirrors the shader.
    static let startRadius: Double = 0.3

    /// Where a ring of `kind` is `age` seconds after its impact, in points, on cells of `cell` points.
    static func ringRadius(of kind: Kind, at age: TimeInterval, cell: CGFloat) -> CGFloat {
        cell * CGFloat(startRadius + kind.ringSpeed * age)
    }

    fileprivate func argument(time: TimeInterval) -> Shader.Argument {
        .float4(Float(x), Float(y), Float(ShaderEffects.wrapped(start: start, time: time)), Float(kind.rawValue))
    }
}

/// A mark on the water: an oil stain where a ship burns (`strength` above 0; 1 is a 25 % darkening,
/// growing for `growth` seconds and then holding), or foam where a shell splashed (`strength` below 0;
/// -1 is the most, fading over `foamLife` seconds). `x`, `y` and `start` are as for `WaterImpact`.
struct WaterStain: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var start: TimeInterval
    var strength: Double

    /// How long an oil stain takes to grow to full size, in seconds. Mirrors `oilDarkening` in Shaders.metal.
    static let growth: TimeInterval = 2
    /// How long foam lasts, in seconds. Mirrors `foamLightening` in Shaders.metal.
    static let foamLife: TimeInterval = 6

    var isFoam: Bool {
        strength < 0
    }

    fileprivate func argument(time: TimeInterval) -> Shader.Argument {
        .float4(Float(x), Float(y), Float(ShaderEffects.wrapped(start: start, time: time)), Float(strength))
    }
}
