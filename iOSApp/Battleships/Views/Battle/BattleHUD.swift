import BattleshipCore
import SwiftUI

/// How the battle HUD arranges itself.
enum BattleHUDLayout {
    /// iPad: one row. The player's board is on screen at full size, so there's no miniature.
    case wide
    /// iPhone: the miniature beside the headline and fleets.
    case compact
    /// Narrow screens and accessibility text sizes: a 64 pt tile of the fleet in the headline row.
    case narrow
}

/// Which view shows the player's waters in the current layout, so every incoming-fire, damage and
/// opening beat has a surface to land on (§2.6).
enum HomeSurface: Equatable, Sendable {
    /// iPad: the full-size board beside the enemy's.
    case board
    /// iPhone: the 106 pt miniature in the HUD.
    case miniMap
    /// Narrow screens and accessibility sizes: a 64 pt tile beside the headline.
    case tile

    /// The miniature's side; the full board sizes itself.
    var side: CGFloat {
        switch self {
        case .board: 0
        case .miniMap: 106
        case .tile: 64
        }
    }
}

/// The opponent's clock in an online game, for the arc draining around the HUD's status dot once
/// their deadline is under a day away (BAT-14).
struct TurnClock: Equatable, Sendable {
    let deadline: Date

    /// The arc is full this long before the deadline.
    static let span: TimeInterval = 24 * 60 * 60
    /// Under this the arc turns red.
    static let urgent: TimeInterval = 60 * 60

    func remaining(at date: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(date))
    }

    /// 0…1 of the arc left to drain.
    func fraction(at date: Date) -> Double {
        min(1, remaining(at: date) / Self.span)
    }

    /// "3 hours left", "45 minutes left", "Out of time".
    func description(at date: Date) -> String {
        let left = remaining(at: date)
        if left <= 0 { return "Out of time" }
        let hours = Int(left / 3600)
        if hours >= 1 { return "\(hours) \(hours == 1 ? "hour" : "hours") left" }
        let minutes = max(1, Int(left / 60))
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes") left"
    }
}

/// Everything the HUD reacts to beyond its words: the controller's counters and the battle's moments.
/// A value, so one `onChange` per cue is enough and the HUD stays a function of what it is given.
struct HUDCues: Equatable {
    /// Bumped by the controller when the turn comes back: the panel sweep, the dot's ring, the wipe and pop.
    var turnStings = 0
    /// Enemy hits on the player's fleet: the jolt, the edge flash, the pull-focus on the home surface.
    var hitsTaken = 0
    /// Bumped every `Timing.idleCue` of the player's turn without input: the headline's glow breathes once.
    var idleCueCount = 0
    /// Bumped for every ring the status dot should emit (INCOMING and the turn coming back).
    var dotBursts = 0
    /// The enemy is lining up a shot: the home surface lifts and its bezel turns red (BAT-4).
    var isBracing = false
    /// The opening is playing and hasn't lit the headline yet: the letters wait, dim (OPN-2).
    var isHeadlineDark = false
    /// Bumped to light the headline letter by letter (the opening's 1.3 s cue).
    var headlineLights = 0
    /// Bumped to move VoiceOver's focus onto the headline (the frame the battle phase appears).
    var focusRequests = 0
    /// A colour for the headline beyond the mood's: gold for LAST SHIP, red for LAST SHIP STANDING.
    var headlineTint: Color? = nil
    /// The lit edge's extra colour (gold for the last-ship callout), or nil for the panel's own.
    var edgeTint: Color? = nil
    /// Cells on the enemy's waters whose shell hasn't landed: their ships stay afloat in the roster meanwhile.
    var pendingTargetCells: Set<Coordinate> = []
    /// The cell on the player's waters the enemy's shell is heading for: not a hit yet.
    var pendingHomeCells: Set<Coordinate> = []
    /// The opponent's clock, when it is worth drawing.
    var turnClock: TurnClock? = nil
    /// A line about the live connection, appended to the status (BAT-14).
    var connectionNote: String? = nil
}

/// The HUD's own beats: keyframe lengths that live beside the views that play them.
private enum HUDBeat {
    /// The light sweep across the panel on a turn handoff.
    static let sweep: TimeInterval = 0.45
    /// The lit edge flashing red on a hit taken (with flashes), or glowing (without).
    static let edgeFlash: TimeInterval = 0.3
    static let edgeGlow: TimeInterval = 0.4
    /// The headline's glow breathing once when the player idles.
    static let breath: TimeInterval = 1.2
    /// The ring the status dot emits.
    static let burst: TimeInterval = 0.6
    /// A roster pip flashing amber twice when its ship is hit: two flashes in 0.8 s stays under three a second.
    static let pipFlash: TimeInterval = 0.8
    /// The home surface pulling focus on a hit taken.
    static let pullFocus: TimeInterval = 0.6
    /// How long the headline keeps its old colour waiting for the turn sting before colouring itself anyway.
    static let stingGrace: TimeInterval = Timing.turnSting * 1.5
}

/// The instrument panel at the top of a battle: whose turn it is in big lit letters, both fleets
/// at a glance and, on iPhone, a miniature of the player's own waters.
struct BattleHUD<MiniMap: View>: View {
    let perspective: BattlePerspective
    let headline: String
    let statusLine: String
    let mood: BattleController.Mood
    var layout: BattleHUDLayout = .compact
    var cues = HUDCues()
    /// Shows the player's board full size, from the narrow layout's tile.
    var onShowFleet: @MainActor () -> Void = {}
    /// The player's waters for the layout: the 106 pt mini map or the 64 pt tile.
    @ViewBuilder let miniMap: (HomeSurface) -> MiniMap

    @Environment(\.motionPolicy) private var policy
    @AccessibilityFocusState private var isHeadlineFocused: Bool

    /// A computed constant: a generic type can't hold a static stored one.
    private static var cornerRadius: CGFloat { 22 }

    var body: some View {
        Group {
            switch layout {
            case .wide:
                HStack(alignment: .center, spacing: 24) {
                    headlineStack
                    Spacer(minLength: 16)
                    rosters
                }
            case .compact:
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        headlineStack
                        Spacer(minLength: 0)
                        rosters
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    miniMap(.miniMap)
                }
                // Lets the rosters settle at the bottom, level with the miniature's caption.
                .fixedSize(horizontal: false, vertical: true)
            case .narrow:
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        headlineStack
                        Spacer(minLength: 12)
                        miniMap(.tile)
                    }
                    rosters
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .hudPanel(cornerRadius: Self.cornerRadius)
        .overlay { litEdge }
        .overlay { handoffSweep }
        .shakes(on: cues.hitsTaken, amplitude: 3, roll: 1)
        .onChange(of: cues.focusRequests) {
            isHeadlineFocused = true
        }
    }

    // MARK: The headline

    private var headlineColor: Color {
        cues.headlineTint ?? mood.color
    }

    private var headlineStack: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                statusDot
                HUDHeadline(text: headline.uppercased(), mood: mood, tint: headlineColor, cues: cues)
            }
            Text(status)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(layout == .narrow ? 4 : 2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(Motion.Curve.state.policy(policy), value: status)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(timeLeft ?? "")
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($isHeadlineFocused)
    }

    private var status: String {
        guard let note = cues.connectionNote else { return statusLine }
        return statusLine.isEmpty ? note : statusLine + " " + note
    }

    /// "5 hours left", folded into what VoiceOver reads for the header.
    private var timeLeft: String? {
        cues.turnClock?.description(at: Date())
    }

    private var statusDot: some View {
        ZStack {
            if let clock = cues.turnClock {
                TurnClockArc(clock: clock)
            }
            PulsingDot(color: headlineColor, isPulsing: mood == .waiting || mood == .danger)
                .battleAnchor(.hudDot)
            DotBurst(trigger: cues.dotBursts, color: headlineColor)
        }
        .frame(width: 18, height: 18)
    }

    // MARK: The panel's light

    /// The lit edge: red for a moment on a hit taken, gold under the last-ship callout.
    private var litEdge: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let flashes = policy.allowsFlashes
        return OneShot(trigger: cues.hitsTaken, duration: flashes ? HUDBeat.edgeFlash : HUDBeat.edgeGlow, curve: Easing.linear) { progress in
            let hit: Double = progress < 1 ? (flashes ? 0.9 * (1 - progress) : 0.5 * sin(.pi * progress)) : 0
            shape
                .strokeBorder(Theme.hit.opacity(hit), lineWidth: 1.5)
                .overlay {
                    if let tint = cues.edgeTint {
                        shape
                            .strokeBorder(tint.opacity(0.8), lineWidth: 1.5)
                            .glow(tint, radius: 6)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.Curve.state.policy(policy), value: cues.edgeTint)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A band of light crossing the panel when the turn comes back; a faint wash without flashes.
    private var handoffSweep: some View {
        PanelSweep(trigger: cues.turnStings, cornerRadius: Self.cornerRadius)
    }

    // MARK: The fleets

    private var rosters: some View {
        VStack(alignment: .leading, spacing: 8) {
            FleetRoster(
                title: "You",
                spokenTitle: "Your fleet",
                ships: RosterShip.mine(in: perspective, pending: cues.pendingHomeCells),
                tint: Theme.hull,
                flashesOnHit: true
            )
            FleetRoster(
                title: "Enemy",
                spokenTitle: "Enemy fleet",
                ships: RosterShip.enemy(in: perspective, pending: cues.pendingTargetCells),
                tint: Theme.hit
            )
        }
    }
}

extension BattleController.Mood {
    var color: Color {
        switch self {
        case .neutral: .white
        case .ready: Theme.reticle
        case .waiting: Theme.amber
        case .danger: Theme.hit
        case .triumph: Theme.gold
        case .defeat: Theme.hit
        }
    }
}

// MARK: - The headline's motion

/// What the headline shows: its words and the mood that colours them.
private struct HeadlineLook: Equatable {
    var text: String
    var mood: BattleController.Mood
    var tint: Color
}

/// One run of the headline's letters: which style, from which colour, and how long.
private struct HeadlineRun: Equatable {
    var id = 0
    var style: KineticStyle = .wipe
    var previousTint: Color = .white
    var duration: TimeInterval = KineticHeadline.letterDuration
}

/// The HUD headline: a `KineticHeadline` whose letters recolour in place. INCOMING drops in as one
/// word; the turn coming back wipes amber to cyan at the sting with a pop and a glow bloom; the
/// opening lights the letters one by one; VICTORY and DEFEAT wipe in at the stamp beat. Under the
/// reduced and still tiers, and at accessibility sizes, the headline is one `Text` that fades.
private struct HUDHeadline: View {
    let text: String
    let mood: BattleController.Mood
    let tint: Color
    let cues: HUDCues

    @Environment(\.motionPolicy) private var policy
    @State private var shown: HeadlineLook?
    @State private var run = HeadlineRun()
    @State private var pops = 0
    /// The words changed to the player's turn: the colour waits for the sting (BAT-6).
    @State private var awaitsSting = false

    private static let size: CGFloat = 22

    var body: some View {
        let look = shown ?? HeadlineLook(text: text, mood: mood, tint: tint)
        let style: KineticStyle = cues.isHeadlineDark ? .lightUp : run.style
        OneShot(trigger: run.id, duration: run.duration, curve: Easing.linear) { progress in
            KineticHeadline(
                text: look.text,
                size: Self.size,
                weight: .heavy,
                style: style,
                tint: AnyShapeStyle(look.tint),
                previousTint: AnyShapeStyle(run.previousTint),
                progress: cues.isHeadlineDark ? 0 : progress,
                glow: look.tint
            )
        }
        .modifier(Breath(trigger: cues.idleCueCount, tint: look.tint))
        .pulse(on: pops, scale: 1.08)
        .onChange(of: HeadlineLook(text: text, mood: mood, tint: tint), initial: true) { _, target in
            follow(target)
        }
        .onChange(of: cues.turnStings) {
            sting()
        }
        .onChange(of: cues.headlineLights) {
            light()
        }
        .task(id: awaitsSting) {
            // The sting is scheduled by the controller; if it never comes, the colour follows anyway.
            guard awaitsSting else { return }
            try? await Task.sleep(for: .seconds(HUDBeat.stingGrace))
            guard !Task.isCancelled, awaitsSting else { return }
            sting()
        }
    }

    private func follow(_ target: HeadlineLook) {
        guard let current = shown else {
            shown = target
            return
        }
        guard current != target else { return }
        // From waiting (amber) or INCOMING (red) to the player's turn (cyan).
        let isHandoff = (current.mood == .waiting || current.mood == .danger) && target.mood == .ready && current.text != target.text
        if isHandoff, policy.tier == .full {
            // The words change at the landing; the colour and the pop wait for the sting.
            shown = HeadlineLook(text: target.text, mood: current.mood, tint: current.tint)
            awaitsSting = true
            return
        }
        awaitsSting = false
        start(target, style: target.text == "INCOMING" ? .drop : .wipe, from: current.tint)
    }

    private func sting() {
        let target = HeadlineLook(text: text, mood: mood, tint: tint)
        let previous = shown?.tint ?? target.tint
        awaitsSting = false
        start(target, style: .wipe, from: previous)
        pops += 1
    }

    private func light() {
        let target = HeadlineLook(text: text, mood: mood, tint: tint)
        awaitsSting = false
        start(target, style: .lightUp, from: target.tint)
    }

    private func start(_ target: HeadlineLook, style: KineticStyle, from previous: Color) {
        shown = target
        let span = max(KineticHeadline.letterDuration, KineticHeadline.span(count: target.text.count))
        run = HeadlineRun(id: run.id + 1, style: style, previousTint: previous, duration: span)
    }
}

/// The headline's glow swelling once, over `HUDBeat.breath`, when the player has been idle a while.
private struct Breath: ViewModifier {
    let trigger: Int
    let tint: Color

    func body(content: Content) -> some View {
        OneShot(trigger: trigger, duration: HUDBeat.breath, curve: Easing.linear) { progress in
            let swell = progress < 1 ? sin(.pi * progress) : 0
            content
                .scaleEffect(1 + 0.02 * swell, anchor: .leading)
                .shadow(color: tint.opacity(0.5 * swell), radius: 14)
        }
    }
}

/// One strong ring radiating from the status dot, each time `trigger` changes.
private struct DotBurst: View {
    let trigger: Int
    let color: Color

    var body: some View {
        OneShot(trigger: trigger, duration: HUDBeat.burst) { progress in
            let scale: CGFloat = 1 + 3.5 * CGFloat(progress)
            let opacity: Double = progress < 1 ? 0.9 * (1 - progress) : 0
            Circle()
                .stroke(color, lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .scaleEffect(scale)
                .opacity(opacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The arc draining around the status dot as the opponent's clock runs down: amber, then red
/// under an hour, read once a minute; it completes red and pulses once when they are out of time.
private struct TurnClockArc: View {
    let clock: TurnClock

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let remaining = clock.remaining(at: context.date)
            let fraction = clock.fraction(at: context.date)
            let tint = remaining < TurnClock.urgent ? Theme.hit : Theme.amber
            Circle()
                .trim(from: 0, to: remaining <= 0 ? 1 : max(0.03, fraction))
                .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 18, height: 18)
                .pulse(on: remaining <= 0, scale: 1.3)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Rosters

/// One ship in a fleet roster.
struct RosterShip: Identifiable, Hashable {
    let id: Int
    let kind: ShipKind
    let isSunk: Bool
    /// Cells of the ship hit so far (the player's own ships; unknown for the enemy's until sunk).
    var hits = 0

    /// The player's fleet. Cells in `pending` have a shell on the way: they don't count yet.
    static func mine(in perspective: BattlePerspective, pending: Set<Coordinate> = []) -> [RosterShip] {
        var remaining = perspective.myFleet
        var roster: [RosterShip] = []
        for kind in perspective.rules.fleet {
            guard let index = remaining.firstIndex(where: { $0.kind == kind }) else { continue }
            let ship = remaining.remove(at: index)
            let landedHits = ship.cells.filter { perspective.homeMark(at: $0) != nil && !pending.contains($0) }.count
            let isSunk = perspective.isMyShipSunk(ship) && !ship.cells.contains { pending.contains($0) }
            roster.append(RosterShip(id: roster.count, kind: kind, isSunk: isSunk, hits: landedHits))
        }
        return roster
    }

    /// The enemy's fleet, with the ships sunk so far crossed off. A ship whose last cell's shell is
    /// still in the air (`pending`) stays afloat until it lands.
    static func enemy(in perspective: BattlePerspective, pending: Set<Coordinate> = []) -> [RosterShip] {
        var sunk = perspective.knownEnemyShips
            .filter { ship in perspective.isEnemyShipSunk(ship) && !ship.cells.contains { pending.contains($0) } }
            .map(\.kind)
        var roster: [RosterShip] = []
        for (index, kind) in perspective.rules.fleet.enumerated() {
            if let match = sunk.firstIndex(of: kind) {
                sunk.remove(at: match)
                roster.append(RosterShip(id: index, kind: kind, isSunk: true))
            } else {
                roster.append(RosterShip(id: index, kind: kind, isSunk: false))
            }
        }
        return roster
    }
}

/// A row of hull silhouettes, one per ship, crossed out once sunk. Where there's no room for the
/// title beside them, it goes above, and the hulls shrink if they still don't fit.
struct FleetRoster: View {
    let title: String
    let spokenTitle: String
    let ships: [RosterShip]
    let tint: Color
    /// The player's own pips flash amber when their ship is hit; the enemy's never do.
    var flashesOnHit = false
    /// Lines up the hulls of the two rosters, and grows with the title.
    @ScaledMetric(relativeTo: .caption2) private var titleWidth: CGFloat = 46

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                label
                    .frame(width: titleWidth, alignment: .leading)
                pips(isCompact: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                label
                pips(isCompact: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                label
                pips(isCompact: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenTitle)
        .accessibilityValue("\(ships.filter { !$0.isSunk }.count) of \(ships.count) ships afloat")
    }

    private var label: some View {
        Text(title.uppercased())
            .tracking(1)
            .scaledFont(10, weight: .heavy, design: .rounded, relativeTo: .caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func pips(isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 3 : 4) {
            ForEach(ships) { ship in
                RosterPip(ship: ship, tint: tint, isCompact: isCompact, flashesOnHit: flashesOnHit)
            }
        }
    }
}

/// A line across a hull: the strike-through of a sunk ship, drawn out with `trim`.
private struct StrikeLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// A hairline crack through a damaged hull.
private struct CrackLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.50, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.56, y: rect.maxY))
        return path
    }
}

/// One roster pip. A hit flashes it amber twice and leaves a crack; a sinking crosses it out with a
/// line that draws itself and lets the hull settle a touch lower, at the stamp beat rather than the
/// landing so the roster doesn't spoil the SUNK stamp.
private struct RosterPip: View {
    let ship: RosterShip
    let tint: Color
    var isCompact = false
    var flashesOnHit = false
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let height: CGFloat = isCompact ? 6 : 8
        let sink = Motion.Curve.settle.delay(Timing.sunkStamp).policy(policy)
        HullShape(kind: ship.kind)
            .fill(ship.isSunk ? AnyShapeStyle(Color.white.opacity(0.1)) : AnyShapeStyle(tint.gradient))
            .overlay {
                if ship.hits > 0, !ship.isSunk {
                    CrackLine()
                        .stroke(Theme.abyss.opacity(0.85), lineWidth: 1)
                        .transition(.opacity)
                }
            }
            .overlay {
                StrikeLine()
                    .trim(from: 0, to: ship.isSunk ? 1 : 0)
                    .stroke(Theme.hit, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-10))
            }
            .overlay { flash }
            .frame(width: width, height: height)
            .offset(y: ship.isSunk ? 1.5 : 0)
            .shadow(color: ship.isSunk ? .clear : tint.opacity(0.5), radius: 3)
            .animation(Motion.Curve.state.policy(policy), value: ship.hits)
            .animation(sink, value: ship.isSunk)
    }

    @ViewBuilder
    private var flash: some View {
        if flashesOnHit {
            let flashes = policy.allowsFlashes
            OneShot(trigger: ship.hits, duration: HUDBeat.pipFlash, curve: Easing.linear) { progress in
                let opacity: Double = flashes && progress < 1 ? 0.9 * abs(sin(2 * .pi * progress)) : 0
                HullShape(kind: ship.kind)
                    .fill(Theme.amber)
                    .opacity(opacity)
            }
            .allowsHitTesting(false)
        }
    }

    private var width: CGFloat {
        isCompact ? max(8, CGFloat(ship.kind.length) * 5) : max(11, CGFloat(ship.kind.length) * 7)
    }
}

// MARK: - The home surface

/// The player's own board in miniature: the 106 pt mini map or the 64 pt tile. Tapping it opens the
/// full-size view. It lifts with a red bezel while the enemy lines up a shot, pulls focus for a
/// moment on a hit taken, and publishes `.homeSurface` for the effects aimed at the player's waters.
/// VoiceOver hears how many ships are afloat from the fleet roster beside it, so the button doesn't
/// repeat it.
struct MiniMapButton: View {
    let perspective: BattlePerspective
    let controller: BattleController
    let isUnderFire: Bool
    let hitsTaken: Int
    var surface: HomeSurface = .miniMap
    /// INCOMING, or the enemy's shell on its way.
    var isBracing = false
    let action: @MainActor () -> Void
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let side = surface == .tile ? HomeSurface.tile.side : HomeSurface.miniMap.side
        Button { action() } label: {
            VStack(spacing: 6) {
                HomeBoard(perspective: perspective, controller: controller, isMiniature: true, isUnderFire: isUnderFire)
                    .frame(width: side, height: side)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.hit.opacity(isBracing ? 0.9 : 0), lineWidth: 1.5)
                            .glow(Theme.hit.opacity(isBracing ? 1 : 0), radius: 6)
                    }
                    .battleAnchor(.homeSurface)
                    .modifier(PullFocus(trigger: hitsTaken))
                    .scaleEffect(isBracing && policy.tier != .still ? 1.06 : 1)
                    .shadow(color: Theme.hit.opacity(isBracing ? 0.45 : 0), radius: 10)
                    .animation(Motion.Curve.settle.policy(policy), value: isBracing)
                    .shakes(on: hitsTaken, amplitude: 4, roll: 1)
                HStack(spacing: 4) {
                    Text("YOUR FLEET")
                    if surface == .miniMap {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                }
                .tracking(0.6)
                .scaledFont(9, weight: .heavy, design: .rounded, relativeTo: .caption2)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your fleet")
        .accessibilityHint("Shows your board full size.")
    }
}

/// The home surface swelling to 1.12 for `HUDBeat.pullFocus` on a hit taken, in the full tier only.
private struct PullFocus: ViewModifier {
    let trigger: Int
    @Environment(\.motionPolicy) private var policy

    func body(content: Content) -> some View {
        let pulls = policy.tier == .full
        OneShot(trigger: trigger, duration: HUDBeat.pullFocus, curve: Easing.linear) { progress in
            let scale: CGFloat = pulls && progress < 1 ? CGFloat(1 + 0.12 * sin(.pi * progress)) : 1
            content.scaleEffect(scale)
        }
    }
}

// MARK: - The Fleet sheet

/// The player's board at full size, with the state of each ship, while the battle goes on. Glass
/// over the battle's own sea (LOB-1): the board scales in from 0.9 and the list follows a beat later.
struct FleetSheet: View {
    let controller: BattleController
    @Environment(\.dismiss) private var dismiss
    @State private var entrance = EntranceClock()

    var body: some View {
        NavigationStack {
            ZStack {
                OceanBackdrop(isAnimated: false)
                if let perspective = controller.perspective {
                    ScrollView {
                        VStack(spacing: 20) {
                            HomeBoard(
                                perspective: perspective,
                                controller: controller,
                                isUnderFire: controller.mood == .danger || controller.mood == .waiting
                            )
                            .shakes(on: controller.hitsTaken)
                            .frame(maxWidth: 520)
                            .staggeredEntrance(index: 0, trigger: entrance, offset: 0, scale: 0.9, stagger: Timing.Stagger.block)

                            ShipStatusList(perspective: perspective, pending: controller.telegraph.map { Set([$0.coordinate]) } ?? [])
                                .frame(maxWidth: 520)
                                .entrance(entrance, step: 1)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .toastHost()
            .navigationTitle("Your Fleet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(32)
        .presentationDragIndicator(.visible)
    }
}

private struct ShipStatusList: View {
    let perspective: BattlePerspective
    /// The cell the enemy's shell is heading for: not a hit until it lands.
    var pending: Set<Coordinate> = []

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(perspective.myFleet.enumerated()), id: \.offset) { index, ship in
                if index > 0 {
                    Divider()
                }
                ShipStatusRow(
                    kind: ship.kind,
                    hits: ship.cells.filter { perspective.homeMark(at: $0) != nil && !pending.contains($0) }.count,
                    isSunk: perspective.isMyShipSunk(ship) && !ship.cells.contains { pending.contains($0) }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .hudPanel(cornerRadius: 18)
    }
}

private struct ShipStatusRow: View {
    let kind: ShipKind
    let hits: Int
    let isSunk: Bool
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        HStack(spacing: 14) {
            ShipView(ship: ShipPlacement(kind: kind, origin: Coordinate(row: 0, column: 0), orientation: .horizontal), isSunk: isSunk)
                .frame(width: CGFloat(kind.length) * 18, height: 15)
                .frame(width: 92, alignment: .leading)
                .accessibilityHidden(true)
            Text(kind.displayName)
                .font(.body.weight(.semibold))
            Spacer(minLength: 8)
            Text(status)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
                .contentTransition(.numericText())
                .animation(Motion.Curve.state.policy(policy), value: status)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        if isSunk { return "Sunk" }
        return hits > 0 ? "\(hits) of \(kind.length) hit" : "Afloat"
    }

    private var statusColor: Color {
        if isSunk { return Theme.hit }
        return hits > 0 ? Theme.amber : Theme.victory
    }
}
