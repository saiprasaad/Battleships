import SwiftUI

/// The colours of the sky band and the sea at one time of day. Every hour stays inside the brand's
/// blue family: dawn and dusk warm the sky band only, night darkens the water to about 60 % of its
/// daytime luminance and never below `abyss`. HUD, fire, reticle and text colours never change.
///
/// `.day` is exactly today's colours (`Theme`'s water and the backdrop's mesh), so screenshots that
/// inject it look as they always did. Palettes are blended by `DayCycle`, so the colours are kept as
/// sRGB components (`Tints`) and handed out as `Color`s.
struct SkyPalette: Equatable, Sendable {
    /// A colour as sRGB components, so palettes can be blended.
    struct Tint: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        var color: Color {
            Color(red: red, green: green, blue: blue)
        }

        /// This tint moved `amount` (0…1) of the way to `other`.
        func mixed(with other: Tint, by amount: Double) -> Tint {
            let t = min(max(amount, 0), 1)
            return Tint(red + (other.red - red) * t, green + (other.green - green) * t, blue + (other.blue - blue) * t)
        }

        /// This tint at `factor` of its brightness.
        func scaled(_ factor: Double) -> Tint {
            Tint(red * factor, green * factor, blue * factor)
        }
    }

    /// Every colour and amount in a palette, as numbers.
    struct Tints: Equatable, Sendable {
        var skyTop: Tint
        var skyHorizon: Tint
        var seaGlow: Tint
        var seaTop: Tint
        var seaBottom: Tint
        var abyss: Tint
        /// The nine colours of the backdrop's mesh: three rows of three, from the top left.
        var backdrop: [Tint]
        /// How bright the glint band on the water is; 1 is today's.
        var glint: Double
        /// How visible the stars are, 0…1.
        var starAlpha: Double

        /// These tints moved `amount` (0…1) of the way to `other`.
        func mixed(with other: Tints, by amount: Double) -> Tints {
            let t = min(max(amount, 0), 1)
            var mixedBackdrop: [Tint] = []
            for (index, tint) in backdrop.enumerated() {
                let target = index < other.backdrop.count ? other.backdrop[index] : tint
                mixedBackdrop.append(tint.mixed(with: target, by: t))
            }
            return Tints(
                skyTop: skyTop.mixed(with: other.skyTop, by: t),
                skyHorizon: skyHorizon.mixed(with: other.skyHorizon, by: t),
                seaGlow: seaGlow.mixed(with: other.seaGlow, by: t),
                seaTop: seaTop.mixed(with: other.seaTop, by: t),
                seaBottom: seaBottom.mixed(with: other.seaBottom, by: t),
                abyss: abyss.mixed(with: other.abyss, by: t),
                backdrop: mixedBackdrop,
                glint: glint + (other.glint - glint) * t,
                starAlpha: starAlpha + (other.starAlpha - starAlpha) * t
            )
        }
    }

    var tints: Tints

    init(tints: Tints) {
        self.tints = tints
    }

    /// The top of the sky band.
    var skyTop: Color { tints.skyTop.color }
    /// The sky at the horizon line.
    var skyHorizon: Color { tints.skyHorizon.color }
    var seaGlow: Color { tints.seaGlow.color }
    var seaTop: Color { tints.seaTop.color }
    var seaBottom: Color { tints.seaBottom.color }
    var abyss: Color { tints.abyss.color }
    /// The nine colours of the backdrop's mesh, three rows of three from the top left; the middle of
    /// each row is the band colour the iOS 17 drift shader paints.
    var backdrop: [Color] { tints.backdrop.map(\.color) }
    /// How bright the glint band on the water is; 1 is today's.
    var glint: Double { tints.glint }
    /// How visible the stars are, 0…1.
    var starAlpha: Double { tints.starAlpha }
    var isNight: Bool { tints.starAlpha >= 0.5 }

    /// This palette moved `amount` (0…1) of the way to `other`.
    func mixed(with other: SkyPalette, by amount: Double) -> SkyPalette {
        SkyPalette(tints: tints.mixed(with: other.tints, by: amount))
    }

    // MARK: The four palettes

    /// Today's colours exactly: `Theme`'s water and the backdrop's mesh as they have always been.
    static let day = SkyPalette(tints: Tints(
        skyTop: Tint(0.05, 0.22, 0.42),
        skyHorizon: Tint(0.06, 0.30, 0.50),
        seaGlow: Tint(0.16, 0.49, 0.76),
        seaTop: Tint(0.08, 0.33, 0.58),
        seaBottom: Tint(0.03, 0.17, 0.36),
        abyss: Tint(0.02, 0.07, 0.16),
        backdrop: dayBackdrop,
        glint: 1,
        starAlpha: 0
    ))

    /// A warm sky band over slate water.
    static let dawn = SkyPalette(tints: Tints(
        skyTop: Tint(0.14, 0.20, 0.42),
        skyHorizon: Tint(0.46, 0.36, 0.44),
        seaGlow: Tint(0.17, 0.44, 0.66),
        seaTop: Tint(0.09, 0.30, 0.52),
        seaBottom: Tint(0.04, 0.16, 0.33),
        abyss: Tint(0.02, 0.07, 0.16),
        backdrop: [
            Tint(0.10, 0.16, 0.34), Tint(0.22, 0.24, 0.44), Tint(0.09, 0.14, 0.32),
            Tint(0.03, 0.16, 0.34), Tint(0.07, 0.29, 0.49), Tint(0.04, 0.15, 0.34),
            dayBackdrop[6], dayBackdrop[7], dayBackdrop[8],
        ],
        glint: 0.9,
        starAlpha: 0.15
    ))

    /// Amber to violet above warmer water, with a wider glint band.
    static let dusk = SkyPalette(tints: Tints(
        skyTop: Tint(0.18, 0.12, 0.38),
        skyHorizon: Tint(0.60, 0.34, 0.30),
        seaGlow: Tint(0.21, 0.47, 0.70),
        seaTop: Tint(0.10, 0.32, 0.55),
        seaBottom: Tint(0.04, 0.17, 0.35),
        abyss: Tint(0.02, 0.07, 0.16),
        backdrop: [
            Tint(0.16, 0.12, 0.34), Tint(0.34, 0.20, 0.40), Tint(0.14, 0.11, 0.32),
            Tint(0.04, 0.16, 0.34), Tint(0.08, 0.29, 0.50), Tint(0.05, 0.14, 0.33),
            dayBackdrop[6], dayBackdrop[7], dayBackdrop[8],
        ],
        glint: 1.3,
        starAlpha: 0.2
    ))

    /// Deep blue at about 60 % of the day's luminance, never black, with a cool moon glint and stars.
    static let night = SkyPalette(tints: Tints(
        skyTop: Tint(0.01, 0.04, 0.12),
        skyHorizon: Tint(0.03, 0.10, 0.22),
        seaGlow: Tint(0.10, 0.30, 0.47),
        seaTop: Tint(0.05, 0.20, 0.36),
        seaBottom: Tint(0.02, 0.11, 0.23),
        abyss: Tint(0.02, 0.07, 0.16),
        backdrop: dayBackdrop.map { $0.scaled(0.6) },
        glint: 0.8,
        starAlpha: 1
    ))

    /// The backdrop's mesh as it has always been drawn.
    private static let dayBackdrop: [Tint] = [
        Tint(0.03, 0.13, 0.29), Tint(0.05, 0.22, 0.42), Tint(0.03, 0.11, 0.27),
        Tint(0.02, 0.15, 0.33), Tint(0.06, 0.30, 0.50), Tint(0.04, 0.14, 0.33),
        Tint(0.01, 0.05, 0.14), Tint(0.02, 0.09, 0.21), Tint(0.01, 0.04, 0.12),
    ]
}

/// The palette for the local time of day: night until 5, dawn blending in by 7 and into the day by 9,
/// the day until 17, dusk by 19, and night again by 21. No location is used, only the clock.
enum DayCycle {
    /// A palette to use instead of the clock's, for screenshots and tests (`ScreenshotTests` set `.day`).
    @MainActor static var fixedPalette: SkyPalette?

    static func palette(at date: Date, calendar: Calendar = .current) -> SkyPalette {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(components.hour ?? 12) + Double(components.minute ?? 0) / 60
        return palette(atHour: hour)
    }

    /// The palette at `hour` on a 24-hour clock (fractions are minutes).
    static func palette(atHour hour: Double) -> SkyPalette {
        var clock = hour.truncatingRemainder(dividingBy: 24)
        if clock < 0 {
            clock += 24
        }
        switch clock {
        case ..<5:
            return .night
        case ..<7:
            return SkyPalette.night.mixed(with: .dawn, by: Easing.easeInOut((clock - 5) / 2))
        case ..<9:
            return SkyPalette.dawn.mixed(with: .day, by: Easing.easeInOut((clock - 7) / 2))
        case ..<17:
            return .day
        case ..<19:
            return SkyPalette.day.mixed(with: .dusk, by: Easing.easeInOut((clock - 17) / 2))
        case ..<21:
            return SkyPalette.dusk.mixed(with: .night, by: Easing.easeInOut((clock - 19) / 2))
        default:
            return .night
        }
    }
}

private struct SkyPaletteKey: EnvironmentKey {
    static let defaultValue = SkyPalette.day
}

extension EnvironmentValues {
    /// The colours of the sky and sea right now. `.day` until a `SkyClock` sets it.
    var skyPalette: SkyPalette {
        get { self[SkyPaletteKey.self] }
        set { self[SkyPaletteKey.self] = newValue }
    }
}

/// Hands `content` the palette for the local time of day as `\.skyPalette`, re-read once a minute.
/// `RootView` wraps the app in it; `DayCycle.fixedPalette` overrides the clock for screenshots.
struct SkyClock<Content: View>: View {
    @ViewBuilder let content: () -> Content

    /// How often the clock is read, in seconds: minutes, not seconds, even in the still tier.
    private static let tick: TimeInterval = 60

    var body: some View {
        TimelineView(.periodic(from: Date(), by: Self.tick)) { context in
            content()
                .environment(\.skyPalette, DayCycle.fixedPalette ?? DayCycle.palette(at: context.date))
        }
    }
}
