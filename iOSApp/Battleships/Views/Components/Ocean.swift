import SwiftUI

/// The living sea behind the app: a slowly drifting mesh of deep blues. It holds still under Reduce
/// Motion and in Low Power Mode, and falls back to a plain gradient before iOS 18.
struct OceanBackdrop: View {
    var extendsIntoSafeArea = true
    /// Off for a small patch of sea laid over the big one, where a second drift would double the work.
    var isAnimated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isStill = !isAnimated || Motion.holdsStill(reduceMotion: reduceMotion)
        Group {
            if #available(iOS 18.0, *) {
                // The drift is slow and soft-edged, so 20 frames a second looks the same as 30.
                TimelineView(.animation(minimumInterval: 1 / 20, paused: isStill)) { timeline in
                    MeshGradient(
                        width: 3,
                        height: 3,
                        points: Self.points(at: isStill ? 0 : timeline.date.timeIntervalSinceReferenceDate),
                        colors: Self.colors
                    )
                }
            } else {
                LinearGradient(colors: [Self.colors[1], Self.colors[4], Self.colors[7]], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea(edges: extendsIntoSafeArea ? .all : [])
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let colors: [Color] = [
        Color(red: 0.03, green: 0.13, blue: 0.29), Color(red: 0.05, green: 0.22, blue: 0.42), Color(red: 0.03, green: 0.11, blue: 0.27),
        Color(red: 0.02, green: 0.15, blue: 0.33), Color(red: 0.06, green: 0.30, blue: 0.50), Color(red: 0.04, green: 0.14, blue: 0.33),
        Color(red: 0.01, green: 0.05, blue: 0.14), Color(red: 0.02, green: 0.09, blue: 0.21), Color(red: 0.01, green: 0.04, blue: 0.12),
    ]

    private static func points(at time: TimeInterval) -> [SIMD2<Float>] {
        let drift = Float(sin(time * 0.31)) * 0.09
        let swell = Float(cos(time * 0.23)) * 0.08
        return [
            [0, 0], [0.5 + drift, 0], [1, 0],
            [0, 0.45 + swell], [0.52 + swell, 0.48 - drift], [1, 0.55 - drift],
            [0, 1], [0.5 - swell, 1], [1, 1],
        ]
    }
}

/// Rolling waves, layered from the distant swell to the near crest, filling the bottom of the frame.
struct WavesView: View {
    var amplitude: CGFloat = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: Motion.holdsStill(reduceMotion: reduceMotion))) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isStill = Motion.holdsStill(reduceMotion: reduceMotion)
        // It can run for the whole of an opponent's turn, so it's held to 30 frames a second.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: isStill)) { timeline in
            SonarBeam(tint: tint, turns: isStill ? 0.15 : Motion.cycle(timeline.date, period: period))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The beam of a sonar sweep, `turns` of the way round.
private struct SonarBeam: View {
    let tint: Color
    let turns: Double

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

/// A round radar display: range rings, a sweeping beam and contacts that fade in and out.
struct RadarScope: View {
    var tint: Color = Theme.reticle
    var contacts: [UnitPoint] = [UnitPoint(x: 0.7, y: 0.3), UnitPoint(x: 0.3, y: 0.64), UnitPoint(x: 0.6, y: 0.76)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isStill = Motion.holdsStill(reduceMotion: reduceMotion)
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .fill(EllipticalGradient(colors: [tint.opacity(0.18), tint.opacity(0.03)], center: .center))
                ForEach(1..<4, id: \.self) { ring in
                    Circle()
                        .stroke(tint.opacity(0.25), lineWidth: 1)
                        .frame(width: side * CGFloat(ring) / 3, height: side * CGFloat(ring) / 3)
                }
                Rectangle()
                    .fill(tint.opacity(0.18))
                    .frame(width: 1, height: side)
                Rectangle()
                    .fill(tint.opacity(0.18))
                    .frame(width: side, height: 1)
                // One clock for the beam and every contact.
                TimelineView(.animation(minimumInterval: 1 / 30, paused: isStill)) { timeline in
                    let now = Motion.seconds(timeline.date)
                    ZStack {
                        SonarBeam(tint: tint, turns: isStill ? 0.15 : Motion.cycle(now, period: 3.6))
                            .clipShape(Circle())
                        ForEach(Array(contacts.enumerated()), id: \.offset) { index, contact in
                            RadarContact(
                                tint: tint,
                                glow: isStill ? 1 : 0.5 + 0.5 * sin(2 * .pi * (now - Double(index) * 0.9) / 2.6)
                            )
                            .position(x: side * contact.x, y: side * contact.y)
                        }
                    }
                    .frame(width: side, height: side)
                }
                Circle()
                    .strokeBorder(tint.opacity(0.5), lineWidth: 1.5)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct RadarContact: View {
    let tint: Color
    /// From 0 (faded out) to 1 (lit).
    let glow: Double

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .glow(tint, radius: 6)
            .opacity(0.12 + 0.88 * glow)
    }
}

/// Concentric rings that ripple outwards, like a sonar ping.
struct SonarPing: View {
    var tint: Color = Theme.reticle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isStill = Motion.holdsStill(reduceMotion: reduceMotion)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: isStill)) { timeline in
            let now = Motion.seconds(timeline.date)
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let progress = isStill ? 0.3 + Double(ring) * 0.25 : Motion.cycle(now + Double(ring) * 0.8, period: 2.4)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !Motion.holdsStill(reduceMotion: reduceMotion) {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let progress = Motion.cycle(timeline.date, period: 1.2)
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
    /// Mode, to save battery.
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
