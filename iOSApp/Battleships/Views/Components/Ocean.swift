import SwiftUI

/// The living sea behind the app: a slowly drifting field of deep blues in the colours of the hour
/// (`\.skyPalette`). On iOS 18 it is a mesh; on iOS 17 the `oceanDrift` shader paints the same bands
/// over a plain gradient, which is also the fallback when shaders are off. One `LoopClock(.scenery)`
/// drives it, so it holds still in the still tier, in Low Power Mode and in the background.
struct OceanBackdrop: View {
    var extendsIntoSafeArea = true
    /// Off for a small patch of sea laid over the big one, where a second drift would double the work,
    /// and for the sea under a sheet.
    var isAnimated = true
    @Environment(\.skyPalette) private var palette

    /// The drift's phase in a still frame.
    static let stillSeconds: TimeInterval = 0

    var body: some View {
        let colors = Self.nine(palette.backdrop, fallback: palette.abyss)
        Group {
            if #available(iOS 18.0, *) {
                MeshBackdrop(colors: colors, isAnimated: isAnimated)
            } else {
                DriftBackdrop(top: colors[1], middle: colors[4], bottom: colors[7], isAnimated: isAnimated)
            }
        }
        .ignoresSafeArea(edges: extendsIntoSafeArea ? .all : [])
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The mesh's points at `time`: the middle row and centre column drifting slowly.
    static func points(at time: TimeInterval) -> [SIMD2<Float>] {
        let drift = Float(sin(time * 0.31)) * 0.09
        let swell = Float(cos(time * 0.23)) * 0.08
        return [
            [0, 0], [0.5 + drift, 0], [1, 0],
            [0, 0.45 + swell], [0.52 + swell, 0.48 - drift], [1, 0.55 - drift],
            [0, 1], [0.5 - swell, 1], [1, 1],
        ]
    }

    /// Exactly nine colours, whatever the palette holds, since the mesh needs no more and no fewer.
    private static func nine(_ colors: [Color], fallback: Color) -> [Color] {
        var nine = Array(colors.prefix(9))
        while nine.count < 9 {
            nine.append(fallback)
        }
        return nine
    }
}

/// The iOS 18 backdrop: a 3 × 3 mesh whose middle points drift.
@available(iOS 18.0, *)
private struct MeshBackdrop: View {
    let colors: [Color]
    let isAnimated: Bool

    var body: some View {
        // The drift is slow and soft-edged, so the scenery rate (20 frames a second) looks the same as 30.
        LoopClock(loop: .scenery, isLive: isAnimated) { seconds in
            MeshGradient(
                width: 3,
                height: 3,
                points: OceanBackdrop.points(at: seconds ?? OceanBackdrop.stillSeconds),
                colors: colors
            )
        }
    }
}

/// The iOS 17 backdrop: three colour bands blended by the `oceanDrift` shader, the middle one
/// drifting as the mesh's points do. Without shaders the gradient underneath shows as it is.
private struct DriftBackdrop: View {
    let top: Color
    let middle: Color
    let bottom: Color
    let isAnimated: Bool
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let drawsShader = policy.allowsShaders && ShaderEffects.isAvailable
        LoopClock(loop: .scenery, isLive: isAnimated && drawsShader) { seconds in
            GeometryReader { proxy in
                LinearGradient(colors: [top, middle, bottom], startPoint: .top, endPoint: .bottom)
                    .colorEffect(
                        ShaderEffects.oceanDrift(
                            time: seconds ?? OceanBackdrop.stillSeconds,
                            size: proxy.size,
                            top: top,
                            middle: middle,
                            bottom: bottom
                        ),
                        isEnabled: drawsShader
                    )
            }
        }
    }
}

/// The ocean with depth, for the welcome screen, the lobby hero and the game-over scrim: a far sky
/// band with a thin horizon line (and stars at night), the drifting sea, and a near wash of light,
/// each on its own `ParallaxLayer` (3 / 7 / 14 points at a full lean) so they slide with the phone
/// through the one shared `TiltSensor`. Below the full tier the layers sit still at centre. Never on
/// the battle screen or the boards.
struct ParallaxOcean: View {
    var extendsIntoSafeArea = true
    var isAnimated = true
    @Environment(\.skyPalette) private var palette

    /// How far each layer moves at a full lean, in points.
    static let skyDepth: CGFloat = 3
    static let seaDepth: CGFloat = 7
    static let washDepth: CGFloat = 14

    var body: some View {
        ZStack {
            ParallaxLayer(depth: Self.seaDepth) {
                OceanBackdrop(extendsIntoSafeArea: extendsIntoSafeArea, isAnimated: isAnimated)
                    .padding(-Self.seaDepth)
            }
            ParallaxLayer(depth: Self.skyDepth) {
                SkyBand(palette: palette)
                    .padding(-Self.skyDepth)
            }
            ParallaxLayer(depth: Self.washDepth) {
                NearWash()
                    .padding(-Self.washDepth)
            }
        }
        .ignoresSafeArea(edges: extendsIntoSafeArea ? .all : [])
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The far layer: the sky in the hour's colours over the top of the sea, a thin horizon line and,
/// at night, the stars.
private struct SkyBand: View {
    let palette: SkyPalette

    /// How much of the height the sky takes.
    private static let proportion: CGFloat = 0.38

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height * Self.proportion
            ZStack(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: palette.skyTop.opacity(0.85), location: 0),
                        .init(color: palette.skyHorizon.opacity(0.5), location: 0.7),
                        .init(color: palette.skyHorizon.opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: height)
                if palette.starAlpha > 0 {
                    StarField(alpha: palette.starAlpha)
                        .frame(height: height * 0.8)
                }
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(height: 1)
                    .offset(y: height * 0.78)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }
}

/// The near layer: a wash of light from the top left, the way `WaterFill` is lit, over a faint
/// shade at the bottom right.
private struct NearWash: View {
    var body: some View {
        LinearGradient(
            colors: [.white.opacity(0.06), .clear, .black.opacity(0.10)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Up to sixty stars in the sky band at night, twinkling slowly at 8 frames a second. Their twinkle
/// amplitude follows `policy.allowsFlashes` (steady under Dim Flashing Lights) and the field holds
/// still with the policy.
private struct StarField: View {
    /// How visible the stars are, 0…1.
    let alpha: Double
    @Environment(\.motionPolicy) private var policy

    private static let frameInterval: TimeInterval = 1 / 8
    private static let count = 60

    var body: some View {
        let twinkles = policy.allowsFlashes && !policy.holdsStill
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !twinkles)) { timeline in
            let time = twinkles ? Motion.seconds(timeline.date) : 0
            let amplitude: Double = twinkles ? 1 : 0
            Canvas { context, size in
                StarField.draw(alpha: alpha, time: time, amplitude: amplitude, in: context, size: size)
            }
        }
        .motionBudgeted(isLive: twinkles)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func draw(alpha: Double, time: Double, amplitude: Double, in context: GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0, alpha > 0 else { return }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<count {
            let x = unit(&state) * size.width
            let y = unit(&state) * size.height
            let radius = 0.5 + unit(&state) * 0.9
            let phase = unit(&state) * 2 * .pi
            let rate = 0.4 + unit(&state) * 0.5
            let base = 0.45 + 0.35 * unit(&state)
            let shimmer = sin(time * rate + phase)   // −1…1
            let brightness = min(max(alpha * (base + shimmer * 0.25 * amplitude), 0), 1)
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(brightness)))
        }
    }

    /// The next number 0…1 of a fixed pseudo-random sequence (a splitmix64 step), so the stars
    /// stay where they are from frame to frame.
    private static func unit(_ state: inout UInt64) -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(1 << 53)
    }
}

/// Rolling waves, layered from the distant swell to the near crest, filling the bottom of the frame.
struct WavesView: View {
    var amplitude: CGFloat = 5

    /// The swell's phase in a still frame.
    private static let stillSeconds: TimeInterval = 0

    var body: some View {
        LoopClock(loop: .ambient) { seconds in
            let time = seconds ?? Self.stillSeconds
            Canvas { context, size in
                WavesView.draw(time: time, amplitude: amplitude, in: context, size: size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Layer {
        let height: CGFloat
        let wavelength: CGFloat
        let speed: CGFloat
        let phase: CGFloat
        let top: Color
        let bottom: Color
    }

    private static let layers = [
        Layer(height: 0.62, wavelength: 0.9, speed: 0.5, phase: 0, top: Theme.seaGlow.opacity(0.55), bottom: Theme.seaBottom.opacity(0.6)),
        Layer(height: 0.42, wavelength: 0.6, speed: -0.8, phase: 1.7, top: Theme.seaTop.opacity(0.85), bottom: Theme.seaBottom.opacity(0.9)),
        Layer(height: 0.24, wavelength: 0.45, speed: 1.1, phase: 3.1, top: Theme.seaBottom, bottom: Theme.abyss),
    ]

    private static func draw(time: TimeInterval, amplitude: CGFloat, in context: GraphicsContext, size: CGSize) {
        guard size.width > 0 else { return }
        for layer in layers {
            let base = size.height * (1 - layer.height)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for x in stride(from: CGFloat(0), through: size.width + 4, by: 4) {
                let angle = x / (size.width * layer.wavelength) * 2 * .pi + CGFloat(time) * layer.speed + layer.phase
                path.addLine(to: CGPoint(x: x, y: base + sin(angle) * amplitude))
            }
            path.addLine(to: CGPoint(x: size.width + 4, y: size.height))
            path.closeSubpath()
            context.fill(
                path,
                with: .linearGradient(
                    Gradient(colors: [layer.top, layer.bottom]),
                    startPoint: CGPoint(x: 0, y: base - amplitude),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }
    }
}

/// A radar sweep: a beam of light turning around the centre, for when something is searching.
struct SonarSweep: View {
    var tint: Color = Theme.reticle
    var period: Double = 3.2

    var body: some View {
        // It can run for the whole of an opponent's turn, so it runs at the ambient rate.
        LoopClock(loop: .ambient) { seconds in
            SonarBeam(tint: tint, turns: seconds.map { Motion.cycle($0, period: period) } ?? SonarBeam.stillTurns)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The beam of a sonar sweep, `turns` of the way round, clockwise from three o'clock, with a faint
/// phosphor trail behind it. Shared by the radar scope and the loaders.
struct SonarBeam: View {
    let tint: Color
    let turns: Double

    /// Where a beam rests in a still frame.
    static let stillTurns = 0.15

    var body: some View {
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height) * 1.5
            ZStack {
                AngularGradient(
                    stops: [
                        .init(color: tint.opacity(0), location: 0),
                        .init(color: tint.opacity(0), location: 0.72),
                        .init(color: tint.opacity(0.32), location: 0.999),
                        .init(color: tint.opacity(0), location: 1),
                    ],
                    center: .center,
                    angle: .zero
                )
                Rectangle()
                    .fill(LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: side / 2, height: 1.5)
                    .offset(x: side / 4)
            }
            .frame(width: side, height: side)
            .rotationEffect(.degrees(turns * 360))
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}

/// A round radar display: range rings, a sweeping beam, fine static scan lines, and contacts that
/// light as the beam passes over them and fade over the next two seconds. `boot` plays the
/// instrument switching on; `lockedContact` holds the beam on one contact.
struct RadarScope: View {
    var tint: Color = Theme.reticle
    var contacts: [UnitPoint] = [UnitPoint(x: 0.7, y: 0.3), UnitPoint(x: 0.3, y: 0.64), UnitPoint(x: 0.6, y: 0.76)]
    /// The instrument booting, 0 (dark) to 1 (running): a line grows from the centre and snaps open
    /// into the disc, the rings trim in clockwise, the crosshair fades up and the beam starts turning
    /// over the last fifth. 1 is a running scope.
    var boot: Double = 1
    /// The index of a contact the beam holds on (an incoming transmission); nil lets it sweep.
    var lockedContact: Int? = nil
    @Environment(\.motionPolicy) private var policy

    /// One turn of the beam, in seconds.
    static let period: Double = 3.6
    /// The scan lines over the dish: fine, and static.
    private static let scanlineOpacity = 0.06

    var body: some View {
        let boot = min(max(self.boot, 0), 1)
        let line = Easing.easeOut(Self.window(boot, from: 0, to: 0.35))
        let dish = Easing.easeOut(Self.window(boot, from: 0.3, to: 0.6))
        let crosshair = Self.window(boot, from: 0.55, to: 0.85)
        let beam = Self.window(boot, from: 0.8, to: 1)
        let drawsScanlines = policy.allowsShaders && ShaderEffects.isAvailable
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                // The boot line, until the dish has opened.
                if dish < 1 {
                    Rectangle()
                        .fill(tint.opacity(0.9))
                        .frame(width: max(0, side * line), height: 1.5)
                        .opacity(1 - dish)
                }
                // The dish: fill, rings, crosshair and scan lines, a static layer outside the loop.
                ZStack {
                    Circle()
                        .fill(EllipticalGradient(colors: [tint.opacity(0.18), tint.opacity(0.03)], center: .center))
                    ForEach(1..<4, id: \.self) { ring in
                        Circle()
                            .trim(from: 0, to: Self.ringProgress(boot, ring: ring))
                            .stroke(tint.opacity(0.25), lineWidth: 1)
                            .rotationEffect(.degrees(-90))
                            .frame(width: side * CGFloat(ring) / 3, height: side * CGFloat(ring) / 3)
                    }
                    Rectangle()
                        .fill(tint.opacity(0.18))
                        .frame(width: 1, height: side)
                        .opacity(crosshair)
                    Rectangle()
                        .fill(tint.opacity(0.18))
                        .frame(width: side, height: 1)
                        .opacity(crosshair)
                }
                .frame(width: side, height: side)
                .colorEffect(
                    ShaderEffects.scanlines(time: 0, size: CGSize(width: side, height: side), opacity: Self.scanlineOpacity),
                    isEnabled: drawsScanlines
                )
                .scaleEffect(x: 1, y: max(dish, 0.001))
                // One clock for the beam and every contact.
                LoopClock(loop: .ambient, isLive: beam > 0 && lockedContact == nil) { seconds in
                    let locked = lockedContact.flatMap { index in contacts.indices.contains(index) ? contacts[index] : nil }
                    let turns = Self.turns(at: seconds, locked: locked)
                    ZStack {
                        SonarBeam(tint: tint, turns: turns)
                            .clipShape(Circle())
                        ForEach(Array(contacts.enumerated()), id: \.offset) { index, contact in
                            RadarContact(
                                tint: tint,
                                glow: Self.glow(of: contact, index: index, turns: turns, isStill: seconds == nil, lockedContact: lockedContact)
                            )
                            .position(x: side * contact.x, y: side * contact.y)
                        }
                    }
                    .frame(width: side, height: side)
                }
                .opacity(beam)
                Circle()
                    .strokeBorder(tint.opacity(0.5), lineWidth: 1.5)
                    .scaleEffect(x: 1, y: max(dish, 0.001))
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where the beam points: locked on a contact, resting in a still frame, or sweeping.
    private static func turns(at seconds: Double?, locked: UnitPoint?) -> Double {
        if let locked {
            return fraction(of: locked)
        }
        guard let seconds else { return SonarBeam.stillTurns }
        return Motion.cycle(seconds, period: period)
    }

    /// How lit a contact is: fully while the beam holds on it, steady in a still frame, otherwise
    /// as the beam last passed it.
    private static func glow(of contact: UnitPoint, index: Int, turns: Double, isStill: Bool, lockedContact: Int?) -> Double {
        if let lockedContact {
            return lockedContact == index ? 1 : 0
        }
        if isStill {
            return 1
        }
        return RadarContact.glow(forContactAt: fraction(of: contact), turns: turns, period: period)
    }

    /// A contact's bearing from the centre as a fraction of a turn, clockwise from three o'clock:
    /// the same measure as the beam's `turns`.
    static func fraction(of contact: UnitPoint) -> Double {
        let angle = atan2(Double(contact.y) - 0.5, Double(contact.x) - 0.5)
        var fraction = angle / (2 * .pi)
        if fraction < 0 {
            fraction += 1
        }
        return fraction
    }

    /// The rings trim in one after another through the middle of the boot.
    private static func ringProgress(_ boot: Double, ring: Int) -> Double {
        let start = 0.35 + Double(ring - 1) * 0.1
        return Easing.easeOut(window(boot, from: start, to: start + 0.25))
    }

    /// `value` as 0…1 across `from`…`to`.
    private static func window(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        return min(max((value - from) / (to - from), 0), 1)
    }
}

/// A contact on a radar display: a dot that the beam lights.
struct RadarContact: View {
    let tint: Color
    /// From 0 (faded out) to 1 (lit).
    let glow: Double

    /// How long a contact takes to light after the beam reaches it (a ramp, not a pop).
    static let ramp = 0.3
    /// How long it takes to fade again.
    static let decay = 2.0

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .glow(tint, radius: 6)
            .opacity(0.12 + 0.88 * glow)
    }

    /// How lit a contact at `fraction` of a turn is when the beam is at `turns` of a turn: it ramps up
    /// over `ramp` seconds as the beam reaches it and decays over `decay` seconds behind it.
    static func glow(forContactAt fraction: Double, turns: Double, period: Double) -> Double {
        var since = turns - fraction
        if since < 0 {
            since += 1
        }
        let seconds = since * period
        if seconds < ramp {
            return seconds / ramp
        }
        return max(0, 1 - (seconds - ramp) / decay)
    }
}

/// Concentric rings that ripple outwards, like a sonar ping.
struct SonarPing: View {
    var tint: Color = Theme.reticle

    private static let period = 2.4
    private static let spacing = 0.8

    var body: some View {
        LoopClock(loop: .ambient) { seconds in
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let progress = seconds.map { Motion.cycle($0 + Double(ring) * Self.spacing, period: Self.period) }
                        ?? (0.3 + Double(ring) * 0.25)
                    Circle()
                        .stroke(tint.opacity(0.5), lineWidth: 1)
                        .scaleEffect(0.2 + 0.8 * Motion.easeOut(progress))
                        .opacity(0.9 * (1 - progress))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A status light. While `isPulsing`, a ring keeps radiating from it.
struct PulsingDot: View {
    let color: Color
    var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .background {
                if isPulsing {
                    PulseRing(color: color)
                }
            }
            .glow(color, radius: 5)
            .accessibilityHidden(true)
    }
}

private struct PulseRing: View {
    let color: Color
    @Environment(\.motionPolicy) private var policy

    private static let period = 1.2

    var body: some View {
        if !policy.loopsHoldStill {
            LoopClock(loop: .ambient) { seconds in
                let progress = seconds.map { Motion.cycle($0, period: Self.period) } ?? 0
                Circle()
                    .stroke(color, lineWidth: 1.5)
                    .scaleEffect(1 + 1.8 * Motion.easeOut(progress))
                    .opacity(0.9 * (1 - progress))
            }
        }
    }
}

/// Clock arithmetic for looping effects. They're drawn from the time on a `TimelineView` rather
/// than animated from `onAppear`, which would also animate the view's first layout.
enum Motion {
    /// Whether looping decoration should hold still: under Reduce Motion, as asked, and in Low Power
    /// Mode, to save battery. Older call sites; new code reads `\.motionPolicy`.
    @MainActor
    static func holdsStill(reduceMotion: Bool) -> Bool {
        reduceMotion || MotionPreferences.shared.isLowPowerModeEnabled
    }

    static func seconds(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
    }

    /// How far through a loop of `period` seconds the clock is, from 0 to 1.
    static func cycle(_ date: Date, period: Double) -> Double {
        cycle(seconds(date), period: period)
    }

    static func cycle(_ seconds: Double, period: Double) -> Double {
        let remainder = seconds.truncatingRemainder(dividingBy: period) / period
        return remainder < 0 ? remainder + 1 : remainder
    }

    static func easeOut(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }
}

extension Font {
    /// Wide, heavy lettering for headlines like VICTORY or YOUR TURN, at a fixed size. Prefer the
    /// `displayFont(_:weight:monospacedDigits:)` view modifier, which follows Dynamic Type.
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }
}
