import SwiftUI

/// Rain over the whole screen for a lost battle: the `rain` colour effect on a (nearly) clear
/// rectangle at the policy's ambience rate, with the spec's envelope from the view's appearance:
/// nothing until `FinaleBeat.rainStart`, full density `rainRamp` later, thinning from `rainThin`
/// and gone at `rainStop`, when the timeline pauses for good. `density` scales the whole envelope
/// and `wind` leans the streaks. Without shaders a Canvas draws 90 streaks instead. In the still
/// tier, and with `isLive` off (the recap), it is one faint, still texture.
struct RainView: View {
    var density: Double = 1
    var wind: Double = 0.3
    var isLive = true
    @State private var start = Date()
    @State private var isOver = false
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let runs = isLive && !isOver
        GeometryReader { proxy in
            LoopClock(loop: .ambient, isLive: runs) { seconds in
                let amount = drawnAmount(at: seconds)
                let time = seconds ?? RainEnvelope.stillSeconds
                Rectangle()
                    // A whisper of fill, so the rectangle is rasterised and the effect has pixels to shade.
                    .fill(Color.black.opacity(0.01))
                    .shaderColorEffect(
                        ShaderEffects.rain(time: time, size: proxy.size, density: amount, wind: wind, tint: RainEnvelope.tint),
                        isEnabled: policy.allowsShaders
                    ) {
                        RainStreaksView(time: time, density: amount, wind: wind)
                    }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            guard isLive else { return }
            try? await Task.sleep(for: .seconds(FinaleBeat.rainStop))
            isOver = true
        }
    }

    /// The density to draw: the envelope while the loop runs, a faint still texture while it holds
    /// (the recap, the still tier), and nothing once the rain has stopped.
    private func drawnAmount(at seconds: Double?) -> Double {
        if isOver { return 0 }
        guard let seconds else { return density * RainEnvelope.stillLevel }
        return density * RainEnvelope.level(at: seconds - start.timeIntervalSinceReferenceDate)
    }
}

/// The rain's density over time, and the look of a still frame.
enum RainEnvelope {
    /// The streaks' colour: pale, a little transparent.
    static let tint = Color(red: 0.86, green: 0.92, blue: 1.0).opacity(0.55)
    /// A still frame shows a faint texture.
    static let stillLevel: Double = 0.45
    /// The shader time of a still frame.
    static let stillSeconds: TimeInterval = 3.7

    /// 0…1: up from `rainStart` over `rainRamp`, full until `rainThin`, down to nothing at `rainStop`.
    nonisolated static func level(at elapsed: TimeInterval) -> Double {
        if elapsed < FinaleBeat.rainStart { return 0 }
        if elapsed < FinaleBeat.rainStart + FinaleBeat.rainRamp {
            return Easing.easeInOut((elapsed - FinaleBeat.rainStart) / FinaleBeat.rainRamp)
        }
        if elapsed < FinaleBeat.rainThin { return 1 }
        if elapsed >= FinaleBeat.rainStop { return 0 }
        return 1 - Easing.easeInOut((elapsed - FinaleBeat.rainThin) / (FinaleBeat.rainStop - FinaleBeat.rainThin))
    }
}

/// The rain without the shader: 90 streaks falling in a Canvas, seeded once, leaning with the wind.
private struct RainStreaksView: View {
    let time: TimeInterval
    let density: Double
    let wind: Double

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            RainStreaks.draw(time: time, density: density, wind: wind, size: size, in: &context)
        }
    }
}

/// The fallback streaks: positions from a fixed seed, read per frame.
enum RainStreaks {
    struct Streak: Sendable {
        /// Across the screen, 0…1.
        let x: Double
        /// Where in its fall it starts, 0…1.
        let phase: Double
        /// Screen heights a second.
        let speed: Double
        /// As a fraction of the screen height.
        let length: Double
        let opacity: Double
    }

    static let count = 90

    /// The same 90 streaks every time.
    static let streaks: [Streak] = {
        var generator = SplitMix64(seed: 0x5EA_7A1_9)
        return (0..<count).map { _ in
            Streak(
                x: Double.random(in: 0...1, using: &generator),
                phase: Double.random(in: 0...1, using: &generator),
                speed: Double.random(in: 0.9...1.3, using: &generator),
                length: Double.random(in: 0.05...0.09, using: &generator),
                opacity: Double.random(in: 0.25...0.5, using: &generator)
            )
        }
    }()

    nonisolated static func draw(time: TimeInterval, density: Double, wind: Double, size: CGSize, in context: inout GraphicsContext) {
        let amount = min(max(density, 0), 1)
        guard amount > 0, size.height > 0 else { return }
        let shown = Int((Double(count) * amount).rounded())
        var path = Path()
        for streak in streaks.prefix(shown) {
            let fall = (time * streak.speed + streak.phase).truncatingRemainder(dividingBy: 1.2) - 0.1
            let yBottom = fall * size.height
            let yTop = yBottom - streak.length * size.height
            // The streak leans with the wind: sideways `wind` points for every point it falls.
            let xBottom = streak.x * size.width + CGFloat(wind) * yBottom
            let xTop = xBottom - CGFloat(wind) * (yBottom - yTop)
            path.move(to: CGPoint(x: xTop, y: yTop))
            path.addLine(to: CGPoint(x: xBottom, y: yBottom))
        }
        context.stroke(path, with: .color(RainEnvelope.tint.opacity(0.8 * amount)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
    }
}

/// The one strike of a lost battle, played on each change of `trigger`: a blue-white light over the
/// sky band (the top 35 % of the screen, with a soft lower edge) rising to opacity 0.45 in
/// `FinaleBeat.strikeIn` and falling over `strikeOut`, with a 0.12 lift of the rest of the screen,
/// additive. Drawn only when the policy allows flashes; nothing at rest.
struct LightningFlash: View {
    let trigger: Int
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        OneShot(trigger: trigger, duration: FinaleBeat.strikeIn + FinaleBeat.strikeOut, curve: { $0 }) { progress in
            let light = policy.allowsFlashes ? Lightning.opacity(at: progress) : 0
            LinearGradient(
                stops: [
                    Gradient.Stop(color: Lightning.tint, location: 0),
                    Gradient.Stop(color: Lightning.tint, location: 0.25),
                    Gradient.Stop(color: Lightning.tint.opacity(0.12), location: 0.4),
                    Gradient.Stop(color: Lightning.tint.opacity(0.12), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(light)
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The strike's shape in time.
enum Lightning {
    static let tint = Color(red: 0.86, green: 0.92, blue: 1.0)
    static let peak: Double = 0.45

    /// The band's opacity `progress` (0…1, linear) through the strike: up in `strikeIn`, down over
    /// `strikeOut`, 0 at rest.
    nonisolated static func opacity(at progress: Double) -> Double {
        let total = FinaleBeat.strikeIn + FinaleBeat.strikeOut
        guard total > 0 else { return 0 }
        let p = min(max(progress, 0), 1)
        guard p < 1 else { return 0 }
        let rise = FinaleBeat.strikeIn / total
        if p < rise {
            return peak * (p / rise)
        }
        let fall = (p - rise) / (1 - rise)
        return peak * (1 - fall) * (1 - fall)
    }
}
