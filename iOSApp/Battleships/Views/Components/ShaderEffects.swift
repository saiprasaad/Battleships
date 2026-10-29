import SwiftUI

/// The shaders in Shaders.metal, as SwiftUI effects.
///
/// Every shader's `time` is seconds on one clock, `Date.timeIntervalSinceReferenceDate` as
/// `Motion.seconds(_:)` reads it from a timeline, and `WaterImpact.start` and `WaterStain.start` are on
/// that same clock. Before it reaches the GPU the clock is folded into a `clockCycle` of 1000 s (see
/// `wrapped(_:)`), so a `Float` keeps millisecond precision however long the app has been running;
/// starts are folded with it (`wrapped(start:time:)`), so an age stays right across the fold.
enum ShaderEffects {
    /// Whether the shader library can be used: the hook `MotionPolicy.allowsShaders` reads, so that a
    /// device whose `default.metallib` failed to load draws every caller's fallback instead. iOS 17 has
    /// no API to ask whether `ShaderLibrary.default` loaded (a missing function only logs when it is
    /// first drawn), so nothing clears it today: `ShaderWarmup` draws every shader once at launch, which
    /// compiles their pipelines, and leaves it true.
    @MainActor static private(set) var isAvailable = true

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

    /// The iOS 17 backdrop (`oceanDrift`): three colour bands, `top` through `middle` to `bottom`,
    /// blended by height, the middle one drifting slowly with `time` as the iOS 18 mesh's points do. The
    /// shaded view's alpha is kept. `size` is the view's size in points.
    static func oceanDrift(time: TimeInterval, size: CGSize, top: Color, middle: Color, bottom: Color) -> Shader {
        ShaderLibrary.default.oceanDrift(
            .float(Float(wrapped(time))),
            .float2(size),
            .color(top),
            .color(middle),
            .color(bottom)
        )
    }

    /// The damage flash's red/cyan split (`chromaticSplit`), for `layerEffect` with a `maxSampleOffset`
    /// that covers `offset`: red is sampled `offset` away and blue `offset` the other way, so edges fringe.
    /// Zero leaves the layer unchanged.
    static func chromaticSplit(offset: CGSize) -> Shader {
        ShaderLibrary.default.chromaticSplit(.float2(offset))
    }

    /// Wind-blown rain (`rain`) over a clear rectangle: the shader emits `tint` at the streaks' coverage,
    /// scaled by `density` (0 is none, and the input unchanged; 1 a downpour); `wind` leans the streaks
    /// (points sideways for every point of fall; 0.3 is brisk). `size` is the rectangle's size in points.
    static func rain(time: TimeInterval, size: CGSize, density: Double, wind: Double, tint: Color) -> Shader {
        ShaderLibrary.default.rain(
            .float(Float(wrapped(time))),
            .float2(size),
            .float(Float(min(max(density, 0), 1))),
            .float(Float(wind)),
            .color(tint)
        )
    }

    /// Scan lines and a rim shade for a radar dish (`scanlines`): every other row darkened by half of
    /// `opacity`, and the edges shaded by up to 0.45 × `opacity`; 0 leaves the input unchanged. The lines
    /// hold still whatever `time` is.
    static func scanlines(time: TimeInterval, size: CGSize, opacity: Double) -> Shader {
        ShaderLibrary.default.scanlines(
            .float(Float(wrapped(time))),
            .float2(size),
            .float(Float(min(max(opacity, 0), 1)))
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

/// Draws every shader once, invisibly, so their GPU pipelines are compiled before a battle needs them:
/// a 1×1 white view under each effect, at opacity 0, hit testing and accessibility off. Place it once,
/// at the root (`RootView`), as early as the app draws. It is also where `ShaderEffects.isAvailable`
/// would be cleared if iOS 17 gave a way to know the library failed to load; it doesn't, so the
/// warm-up leaves the flag true.
struct ShaderWarmup: View {
    private static let unit = CGSize(width: 1, height: 1)

    var body: some View {
        ZStack {
            probe.colorEffect(ShaderEffects.tint(.white))
            probe.colorEffect(ShaderEffects.water(time: 0, size: Self.unit, seaState: 0))
            probe.distortionEffect(ShaderEffects.ripples(time: 0, size: Self.unit, cell: 1, impacts: []), maxSampleOffset: .zero)
            probe.colorEffect(ShaderEffects.stains(time: 0, cell: 1, stains: []))
            probe.colorEffect(ShaderEffects.oceanDrift(time: 0, size: Self.unit, top: .white, middle: .white, bottom: .white))
            probe.layerEffect(ShaderEffects.chromaticSplit(offset: .zero), maxSampleOffset: .zero)
            probe.colorEffect(ShaderEffects.rain(time: 0, size: Self.unit, density: 1, wind: 0, tint: .white))
            probe.colorEffect(ShaderEffects.scanlines(time: 0, size: Self.unit, opacity: 1))
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The pixel each shader is drawn on.
    private var probe: some View {
        Color.white.frame(width: 1, height: 1)
    }
}

extension View {
    /// `colorEffect(shader)` when `isEnabled` (the caller's `policy.allowsShaders`, and whatever else
    /// gates the effect), else `fallback` drawn over the content: the static stand-in for what the
    /// shader would have added, so a device whose library failed to load still shows something.
    @ViewBuilder
    func shaderColorEffect<Fallback: View>(_ shader: Shader, isEnabled: Bool, @ViewBuilder fallback: () -> Fallback) -> some View {
        if isEnabled {
            colorEffect(shader)
        } else {
            overlay { fallback() }
        }
    }
}
