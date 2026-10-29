import SwiftUI

/// A warship riding the swell, rocking gently. Under way (`course` other than 0) it rolls less and
/// lifts its bow a touch in the direction it is going. It runs on a `LoopClock(.scenery)` of its own
/// unless the caller hands it the scenery `time` from a clock it already runs, so a scene keeps to
/// one timeline; either way it holds still with the policy.
struct SailingShip: View {
    /// −1…1: how fast the ship is moving and which way (negative is to the left). 0 is moored.
    var course: Double = 0
    /// Scenery seconds from the caller's clock; nil runs a clock here.
    var time: TimeInterval? = nil

    /// The swell's phase in a still frame.
    private static let stillSeconds: TimeInterval = 0

    var body: some View {
        if let time {
            ShipFigure(time: time, course: course)
        } else {
            LoopClock(loop: .scenery) { seconds in
                ShipFigure(time: seconds ?? Self.stillSeconds, course: course)
            }
        }
    }
}

/// The warship at one moment of the swell.
private struct ShipFigure: View {
    let time: TimeInterval
    let course: Double

    var body: some View {
        let speed = min(1, abs(course))
        let heading: Double = course >= 0 ? 1 : -1
        WarshipProfile()
            .fill(
                LinearGradient(
                    colors: [Theme.superstructure, Theme.hull, Theme.hullShadow, Theme.gunMetal],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            // The bow is to the right, so a ship steaming right lifts it with a turn to the left.
            .rotationEffect(.degrees(sin(time * 1.3) * 2.2 * (1 - 0.6 * speed) - 1.5 * speed * heading), anchor: .bottom)
            .offset(y: sin(time * 1.7) * 1.8)
            .accessibilityHidden(true)
    }
}

/// The horizon's life (LOB-7) as a function of scenery time, so a scene draws it from one clock and a
/// test can pick its moment: the ship's voyage across the scene (`crossing` seconds right to left,
/// away for `gap`, back as a far silhouette), the gulls' flights (one to three birds every 15 to 40
/// seconds, on a shallow arc across the sky), the lighthouse lamp (two flashes every six seconds, or
/// a one-second fade at 0.4 where flashes are off) and the smoke puffs trailing a ship under way.
enum HorizonLife {
    /// How long the ship takes to cross the scene, and how long it stays away before coming back.
    static let crossing: TimeInterval = 90
    static let gap: TimeInterval = 20
    /// The gulls' timetable repeats every `gullCycle` seconds; a flight crosses in `flight` seconds.
    static let gullCycle: TimeInterval = 240
    static let flight: TimeInterval = 9
    static let blinkCycle: TimeInterval = 6
    static let flashLength: TimeInterval = 0.25
    static let secondFlash: TimeInterval = 0.8
    /// How long a smoke puff lives, and how far apart the three puffs are.
    static let puffLife: TimeInterval = 4
    static let puffSpacing: TimeInterval = 1.3

    /// A fixed scenery time for stills (the screenshot tests set it), so the ship, a flight of gulls
    /// and the lit lamp are always in the picture, and nothing drifts between runs.
    @MainActor static var fixedTime: TimeInterval?

    /// One flight of gulls: when it starts in the cycle, how many birds, which way, how high
    /// (0 the top of the sky band, 1 the horizon).
    struct Flight: Sendable {
        let start: TimeInterval
        let count: Int
        let leftward: Bool
        let lane: Double
    }

    static let flights: [Flight] = [
        Flight(start: 3, count: 2, leftward: false, lane: 0.3),
        Flight(start: 29, count: 1, leftward: true, lane: 0.5),
        Flight(start: 61, count: 3, leftward: false, lane: 0.2),
        Flight(start: 84, count: 1, leftward: false, lane: 0.6),
        Flight(start: 120, count: 2, leftward: true, lane: 0.35),
        Flight(start: 148, count: 1, leftward: false, lane: 0.45),
        Flight(start: 181, count: 3, leftward: true, lane: 0.25),
        Flight(start: 213, count: 2, leftward: false, lane: 0.55),
    ]

    struct Voyage: Equatable, Sendable {
        /// 0 entering at the right, 1 gone off the left.
        var progress: Double
        /// The second crossing: smaller, higher, dimmer.
        var isFar: Bool
    }

    struct Gull: Equatable, Sendable {
        /// Across the scene, 0…1 (a little beyond at either end).
        var x: Double
        /// Down the sky band, 0…1.
        var y: Double
        /// −1…1: the wings' beat.
        var wing: Double
        var size: Double
    }

    /// What the scene draws at one moment.
    struct Frame: Equatable, Sendable {
        /// The clock is running: a ship may be on its voyage, and in the gap it is gone.
        var isLive: Bool
        var isLively: Bool
        var voyage: Voyage?
        var gulls: [Gull]
        /// The lamp's brightness, 0…1.
        var lamp: Double
        /// Each puff's age, 0…1, oldest first; empty with no ship under way.
        var smoke: [Double]
        var isNight: Bool
    }

    /// The frame at `time` (nil: the clock holds still) for a scene with `isLively` (gulls, lighthouse,
    /// night lights) and `voyages` (the ship crosses) on.
    static func frame(at time: TimeInterval?, isLively: Bool, voyages: Bool, isNight: Bool, allowsFlashes: Bool) -> Frame {
        guard let time else {
            return Frame(isLive: false, isLively: isLively, voyage: nil, gulls: [], lamp: isLively ? 0.4 : 0, smoke: [], isNight: isNight)
        }
        let voyage = voyages ? self.voyage(at: time) : nil
        let gulls = isLively && !isNight ? self.gulls(at: time) : []
        let lamp = isLively ? self.lamp(at: time, allowsFlashes: allowsFlashes) : 0
        let smoke = voyage == nil ? [] : (0..<3).map { puff in
            wrap(time + Double(puff) * puffSpacing, puffLife) / puffLife
        }
        return Frame(isLive: true, isLively: isLively, voyage: voyage, gulls: gulls, lamp: lamp, smoke: smoke, isNight: isNight)
    }

    /// Where the ship is on its voyage at `time`, or nil while it is away.
    static func voyage(at time: TimeInterval) -> Voyage? {
        let leg = crossing + gap
        let t = wrap(time, leg * 2)
        let isFar = t >= leg
        let progress = (t - (isFar ? leg : 0)) / crossing
        guard progress <= 1 else { return nil }
        return Voyage(progress: progress, isFar: isFar)
    }

    /// The gulls in the air at `time`.
    static func gulls(at time: TimeInterval) -> [Gull] {
        let t = wrap(time, gullCycle)
        var gulls: [Gull] = []
        for flight in flights {
            let along = (t - flight.start) / self.flight
            guard along >= 0, along <= 1 else { continue }
            for index in 0..<flight.count {
                let u = along - Double(index) * 0.035
                let x = flight.leftward ? 1.08 - 1.16 * u : -0.08 + 1.16 * u
                let y = flight.lane + Double(index) * 0.07 - 0.12 * sin(.pi * min(1, max(0, u)))
                let wing = sin(2 * .pi * 3 * (time + Double(index) * 0.17))
                gulls.append(Gull(x: x, y: y, wing: wing, size: flight.leftward ? 6 : 7.5))
            }
        }
        return gulls
    }

    /// The lamp at `time`: two flashes a cycle, or a one-second fade at 0.4 where flashes are off,
    /// over a faint resting glow.
    static func lamp(at time: TimeInterval, allowsFlashes: Bool) -> Double {
        let phase = wrap(time, blinkCycle)
        if allowsFlashes {
            let isLit = phase < flashLength || (phase >= secondFlash && phase < secondFlash + flashLength)
            return isLit ? 1 : 0.12
        }
        return 0.12 + 0.28 * max(0, 1 - phase)
    }

    /// `value` folded into 0..<`period`, for negative values too.
    static func wrap(_ value: Double, _ period: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: period)
        return remainder < 0 ? remainder + period : remainder
    }
}

/// The sea's surface with a warship on it, for the bottom edge of a banner or screen. The ship can
/// steam in from the left edge to its mooring (`shipEntrance` from 0 to 1), trailing a wake. With
/// `isLively` the horizon lives (LOB-7): one to three gulls cross the sky every 15 to 40 seconds, a
/// lighthouse on the left headland blinks twice every six seconds with a faint beam, and at night
/// the ship shows running lights and the gulls are gone. With `shipVoyages` the moored ship instead
/// steams right to left across the scene over `HorizonLife.crossing` seconds, trailing a wake line
/// and smoke puffs, and comes back after a gap as a smaller, more distant silhouette. One
/// `LoopClock(.scenery)` drives it all; the still tier holds the ship moored, the gulls away and
/// the lamp steady, and without flashes the blink is a one-second fade.
struct HorizonScene: View {
    /// Where the ship sits, from 0 (left) to 1 (right).
    var shipPosition: CGFloat = 0.62
    var shipWidth: CGFloat = 150
    /// The ship's arrival: 0 is off the left edge, 1 moored at `shipPosition`. The welcome's reveal
    /// drives it; everywhere else the ship is moored from the start.
    var shipEntrance: Double = 1
    var isLively = false
    var shipVoyages = false
    /// Added to the scenery clock, so a strip can start at a chosen moment of the timetable.
    var sceneryTimeOffset: TimeInterval = 0
    @Environment(\.skyPalette) private var palette
    @Environment(\.motionPolicy) private var policy

    /// The swell's phase in a still frame.
    private static let stillSeconds: TimeInterval = 0
    /// The far ship sits this much higher, nearer the horizon.
    private static let farLift: CGFloat = 7

    var body: some View {
        let fixedTime = HorizonLife.fixedTime
        GeometryReader { proxy in
            LoopClock(loop: .scenery, isLive: fixedTime == nil) { seconds in
                let time = fixedTime ?? seconds.map { $0 + sceneryTimeOffset }
                let life = HorizonLife.frame(
                    at: time, isLively: isLively, voyages: shipVoyages, isNight: palette.isNight, allowsFlashes: policy.allowsFlashes
                )
                scene(life, swell: time ?? Self.stillSeconds, size: proxy.size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func scene(_ life: HorizonLife.Frame, swell: TimeInterval, size: CGSize) -> some View {
        let arrival = Easing.easeOut(min(max(shipEntrance, 0), 1))
        let mooring = size.width * shipPosition - shipWidth / 2
        let waterline = -size.height * 0.24
        let ship = placement(arrival: arrival, mooring: mooring, life: life, sceneWidth: size.width)
        let shipHeight = shipWidth * 0.3
        return ZStack(alignment: .bottomLeading) {
            SceneryBack(life: life, size: size, waterline: size.height * 0.76)
            if let ship {
                let width = shipWidth * ship.scale
                let height = shipHeight * ship.scale
                if ship.wake > 0.001 {
                    ShipWake(strength: ship.wake)
                        .frame(width: width * 0.9, height: 3)
                        .scaleEffect(x: ship.facesLeft ? -1 : 1)
                        .offset(x: ship.facesLeft ? ship.x + width * 0.85 : ship.x - width * 0.75, y: waterline - height * 0.2 - ship.lift)
                }
                SailingShip(course: ship.course, time: swell)
                    .frame(width: width, height: height)
                    .scaleEffect(x: ship.facesLeft ? -1 : 1)
                    .opacity(ship.opacity)
                    .offset(x: ship.x, y: waterline - ship.lift)
                SceneryFront(life: life, ship: ship, shipWidth: width, shipHeight: height, size: size, waterline: size.height * 0.76 - ship.lift)
            }
            WavesView(amplitude: 4)
                .frame(height: size.height * 0.62)
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
    }

    /// Where the ship is: arriving, moored, or on its voyage; nil while it is away over the horizon.
    private func placement(arrival: Double, mooring: CGFloat, life: HorizonLife.Frame, sceneWidth: CGFloat) -> HorizonShip? {
        if arrival < 1 {
            let underway = 1 - arrival
            return HorizonShip(
                x: -shipWidth + (mooring + shipWidth) * CGFloat(arrival), scale: 1, course: underway,
                facesLeft: false, opacity: 1, lift: 0, wake: underway
            )
        }
        if let voyage = life.voyage {
            let scale: CGFloat = voyage.isFar ? 0.62 : 1
            let width = shipWidth * scale
            let x = sceneWidth + width - (sceneWidth + 2 * width) * CGFloat(voyage.progress)
            return HorizonShip(
                x: x, scale: scale, course: 0.6, facesLeft: true,
                opacity: voyage.isFar ? 0.72 : 1, lift: voyage.isFar ? Self.farLift : 0, wake: 1
            )
        }
        if shipVoyages, life.isLive {
            return nil
        }
        return HorizonShip(x: mooring, scale: 1, course: 0, facesLeft: false, opacity: 1, lift: 0, wake: 0)
    }

    // MARK: Drawing the life

    /// The lighthouse on the left headland: a rock, a tapered tower with a pale band, the gallery, and
    /// the lamp with its beam fanning out over the water at `lamp` brightness.
    nonisolated static func drawLighthouse(lamp: Double, waterline: CGFloat, in context: inout GraphicsContext) {
        let base = CGPoint(x: 26, y: waterline)
        context.fill(
            Path(ellipseIn: CGRect(x: base.x - 22, y: base.y - 6, width: 44, height: 12)),
            with: .color(Theme.abyss.opacity(0.95))
        )
        var tower = Path()
        tower.move(to: CGPoint(x: base.x - 4.5, y: base.y - 2))
        tower.addLine(to: CGPoint(x: base.x + 4.5, y: base.y - 2))
        tower.addLine(to: CGPoint(x: base.x + 3, y: base.y - 22))
        tower.addLine(to: CGPoint(x: base.x - 3, y: base.y - 22))
        tower.closeSubpath()
        context.fill(tower, with: .color(Theme.gunMetal.opacity(0.9)))
        context.fill(Path(CGRect(x: base.x - 3.6, y: base.y - 14, width: 7.2, height: 3)), with: .color(Theme.hull.opacity(0.55)))
        context.fill(Path(CGRect(x: base.x - 3.5, y: base.y - 26, width: 7, height: 4)), with: .color(Theme.gunMetal))
        let light = CGPoint(x: base.x, y: base.y - 24)
        let glow = Theme.ember.opacity(0.35 * lamp)
        var fan = Path()
        fan.move(to: light)
        fan.addLine(to: CGPoint(x: light.x + 70, y: light.y - 14))
        fan.addLine(to: CGPoint(x: light.x + 70, y: light.y + 10))
        fan.closeSubpath()
        context.fill(
            fan,
            with: .linearGradient(
                Gradient(colors: [glow, Theme.ember.opacity(0)]),
                startPoint: light,
                endPoint: CGPoint(x: light.x + 70, y: light.y)
            )
        )
        context.fill(Path(ellipseIn: CGRect(x: light.x - 2.5, y: light.y - 2.5, width: 5, height: 5)), with: .color(Theme.ember.opacity(0.2 + 0.8 * lamp)))
    }

    /// Each gull: two wings meeting at the body, beating with `wing`.
    nonisolated static func drawGulls(_ gulls: [HorizonLife.Gull], size: CGSize, in context: inout GraphicsContext) {
        let band = CGRect(x: 0, y: size.height * 0.04, width: size.width, height: size.height * 0.34)
        for gull in gulls {
            let s = gull.size
            let x = band.minX + CGFloat(gull.x) * band.width
            let y = band.minY + CGFloat(gull.y) * band.height
            let lift = s * 0.55 * gull.wing
            var path = Path()
            path.move(to: CGPoint(x: x - s, y: y - lift * 0.4))
            path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x - s * 0.5, y: y - lift))
            path.addQuadCurve(to: CGPoint(x: x + s, y: y - lift * 0.4), control: CGPoint(x: x + s * 0.5, y: y - lift))
            context.stroke(path, with: .color(Color.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }

    /// The smoke from the funnel of a ship under way: three puffs rising, drifting astern, growing
    /// and dissolving.
    nonisolated static func drawSmoke(_ ages: [Double], funnel: CGPoint, astern: CGFloat, scale: CGFloat, in context: inout GraphicsContext) {
        for age in ages {
            let a = CGFloat(age)
            let radius = (2 + 7 * a) * scale
            let center = CGPoint(x: funnel.x + astern * 16 * a * scale, y: funnel.y - 18 * a * scale)
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(Color.white.opacity(0.28 * (1 - age)))
            )
        }
    }

    /// A ship's running lights at night: red astern, green at the bow, white at the masthead.
    nonisolated static func drawRunningLights(bow: CGPoint, stern: CGPoint, mast: CGPoint, in context: inout GraphicsContext) {
        for (point, color) in [(stern, Color.red), (bow, Color.green), (mast, Color.white)] {
            context.fill(Path(ellipseIn: CGRect(x: point.x - 1.3, y: point.y - 1.3, width: 2.6, height: 2.6)), with: .color(color.opacity(0.9)))
        }
    }
}

/// The ship's place in the scene at one moment.
private struct HorizonShip {
    var x: CGFloat
    var scale: CGFloat
    var course: Double
    var facesLeft: Bool
    var opacity: Double
    var lift: CGFloat
    /// 0…1: how strong a wake to draw.
    var wake: Double
}

/// What lies behind the ship: the lighthouse and the gulls.
private struct SceneryBack: View {
    let life: HorizonLife.Frame
    let size: CGSize
    let waterline: CGFloat

    var body: some View {
        Canvas { context, _ in
            if life.isLively {
                HorizonScene.drawLighthouse(lamp: life.lamp, waterline: waterline, in: &context)
            }
            HorizonScene.drawGulls(life.gulls, size: size, in: &context)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// What lies over the ship: its smoke under way and its running lights at night.
private struct SceneryFront: View {
    let life: HorizonLife.Frame
    let ship: HorizonShip
    let shipWidth: CGFloat
    let shipHeight: CGFloat
    let size: CGSize
    let waterline: CGFloat

    var body: some View {
        Canvas { context, _ in
            let bowSide: CGFloat = ship.facesLeft ? 0.12 : 0.88
            let funnel = CGPoint(x: ship.x + shipWidth * (ship.facesLeft ? 0.46 : 0.54), y: waterline - shipHeight * 0.85)
            if !life.smoke.isEmpty {
                HorizonScene.drawSmoke(life.smoke, funnel: funnel, astern: ship.facesLeft ? 1 : -1, scale: ship.scale, in: &context)
            }
            if life.isNight, life.isLively {
                HorizonScene.drawRunningLights(
                    bow: CGPoint(x: ship.x + shipWidth * bowSide, y: waterline - shipHeight * 0.45),
                    stern: CGPoint(x: ship.x + shipWidth * (1 - bowSide), y: waterline - shipHeight * 0.4),
                    mast: CGPoint(x: funnel.x, y: waterline - shipHeight * 0.98),
                    in: &context
                )
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// A pale line of foam behind a ship under way, brightest at the stern.
private struct ShipWake: View {
    /// 0…1: how fast the ship is going.
    let strength: Double

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.35)], startPoint: .leading, endPoint: .trailing))
            .opacity(strength)
    }
}
