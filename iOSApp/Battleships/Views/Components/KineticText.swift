import SwiftUI

/// How a headline's letters arrive.
enum KineticStyle {
    /// Each letter slams in from large to its size.
    case slam
    /// Each letter drops in from above.
    case drop
    /// The letters are there, dim, and light up in turn.
    case lightUp
    /// The letters recolour from `previousTint` to `tint` in turn.
    case wipe
}

/// A headline whose letters move. Splits the text by grapheme cluster, animates each from
/// `progress` (0…1 for the whole word) staggered by `Timing.Stagger.letter`, and is one
/// accessibility element with the whole string. Falls back to a single `Text` that only fades
/// when: the text size is an accessibility size, the available width is under 300 pt, the layout
/// is right-to-left, the string has a scalar outside Latin, Greek, Cyrillic, digits and
/// punctuation (combining marks and complex scripts must not be split), or sequences collapse.
/// Any glow is one animated shadow on the whole word, never one per letter.
struct KineticHeadline: View {
    let text: String
    var size: CGFloat = 34
    var weight: Font.Weight = .black
    var style: KineticStyle = .slam
    var tint: AnyShapeStyle = AnyShapeStyle(Color.white)
    /// `.wipe`: letters recolour from this to `tint`.
    var previousTint: AnyShapeStyle? = nil
    /// 0…1 for the whole word.
    let progress: Double
    /// 0…1 position of a light sweep across the word, drawn only when the policy allows flashes.
    var sweep: Double? = nil
    /// A halo in this colour, one shadow on the whole word, swelling as the word lands.
    var glow: Color? = nil

    @Environment(\.motionPolicy) private var policy
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection

    /// Below this width the word is one `Text` that can wrap and shrink.
    nonisolated static let minimumWidth: CGFloat = 300
    /// Each letter's own move takes this long, in word time, before the next starts after `Timing.Stagger.letter`.
    /// Nonisolated so a plain struct can use it as a default value (`HeadlineRun` in the HUD).
    nonisolated static let letterDuration: TimeInterval = 0.25

    var body: some View {
        Group {
            if let letters = Self.letters(of: text), usesLetters {
                ViewThatFits(in: .horizontal) {
                    lettersRow(letters)
                        .frame(minWidth: Self.minimumWidth)
                    fallback
                }
            } else {
                fallback
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var usesLetters: Bool {
        !dynamicTypeSize.isAccessibilitySize && layoutDirection == .leftToRight && !policy.collapsesSequences
    }

    /// The single-`Text` version: a fade.
    private var fallback: some View {
        Text(text)
            .displayFont(size, weight: weight)
            .foregroundStyle(tint)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.center)
            .opacity(Motion.easeOut(progress))
            .shadow(color: glowColor, radius: glowRadius)
    }

    private func lettersRow(_ letters: [String]) -> some View {
        let span = Self.span(count: letters.count)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(letters.enumerated()), id: \.offset) { index, letter in
                letterView(letter, progress: Self.letterProgress(index: index, of: progress, span: span))
            }
        }
        .lineLimit(1)
        .overlay {
            if let sweep, policy.flashes {
                sweepLight(at: sweep)
                    .mask(alignment: .leading) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            ForEach(Array(letters.enumerated()), id: \.offset) { _, letter in
                                Text(letter).displayFont(size, weight: weight)
                            }
                        }
                    }
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: glowColor, radius: glowRadius)
    }

    @ViewBuilder
    private func letterView(_ letter: String, progress: Double) -> some View {
        let eased = Motion.easeOut(progress)
        let base = Text(letter).displayFont(size, weight: weight)
        switch style {
        case .slam:
            base
                .foregroundStyle(tint)
                .scaleEffect(1 + 0.9 * (1 - eased))
                .opacity(eased)
        case .drop:
            base
                .foregroundStyle(tint)
                .offset(y: -0.7 * size * (1 - eased))
                .opacity(min(1, progress * 3))
        case .lightUp:
            base
                .foregroundStyle(tint)
                .opacity(0.22 + 0.78 * eased)
        case .wipe:
            ZStack {
                base.foregroundStyle(previousTint ?? tint)
                base.foregroundStyle(tint).opacity(eased)
            }
        }
    }

    /// A band of light `position` (0…1) of the way across the word.
    private func sweepLight(at position: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let band = max(40, width * 0.3)
            LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: -band + (width + band) * min(max(position, 0), 1))
        }
    }

    private var glowColor: Color {
        glow?.opacity(0.7) ?? .clear
    }

    /// Swells as the word lands, then settles: 6 at rest, 16 in the middle of the move.
    private var glowRadius: CGFloat {
        guard glow != nil else { return 0 }
        return 6 + 10 * sin(.pi * min(max(progress, 0), 1))
    }

    // MARK: Splitting

    /// The whole word's time, in letter units: the last letter starts after the staggers and takes `letterDuration`.
    static func span(count: Int) -> Double {
        Double(max(0, count - 1)) * Timing.Stagger.letter + letterDuration
    }

    /// Letter `index`'s own 0…1 when the word is `progress` of the way through.
    static func letterProgress(index: Int, of progress: Double, span: Double) -> Double {
        let time = min(max(progress, 0), 1) * span
        return min(1, max(0, (time - Double(index) * Timing.Stagger.letter) / letterDuration))
    }

    /// The grapheme clusters to animate, or nil when the text has a scalar outside Latin, Greek,
    /// Cyrillic, digits and punctuation: combining marks and complex scripts are never split.
    static func letters(of text: String) -> [String]? {
        guard !text.isEmpty else { return nil }
        for scalar in text.unicodeScalars where !isSplittable(scalar) {
            return nil
        }
        return text.map { String($0) }
    }

    private static func isSplittable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20...0x7E,       // Basic Latin: letters, digits, punctuation, space
             0xA0...0xFF,       // Latin-1 Supplement: precomposed letters, punctuation
             0x100...0x24F,     // Latin Extended-A and B
             0x370...0x3FF,     // Greek and Coptic
             0x400...0x4FF,     // Cyrillic
             0x2010...0x2027,   // dashes, quotes, bullets, the ellipsis
             0x2030...0x205E:   // per mille, primes, more punctuation
            return true
        default:
            return false
        }
    }
}

/// A centred title with a thin rule under it, no bars: the three title moments only. `progress`
/// runs the title in, draws the rule out from the centre, then fades the caption.
struct TitleCard: View {
    let title: String
    var caption: String? = nil
    var tint: Color = .white
    let progress: Double

    var body: some View {
        VStack(spacing: 10) {
            KineticHeadline(
                text: title,
                size: 34,
                weight: .black,
                style: .slam,
                tint: AnyShapeStyle(tint),
                progress: Self.window(progress, from: 0, to: 0.7),
                glow: tint
            )
            Rectangle()
                .fill(tint.opacity(0.6))
                .frame(height: 1)
                .frame(maxWidth: 180)
                .scaleEffect(x: max(0.001, Motion.easeOut(Self.window(progress, from: 0.4, to: 0.8))), y: 1)
                .accessibilityHidden(true)
            if let caption {
                Text(caption)
                    .font(.subheadline.weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .opacity(Motion.easeOut(Self.window(progress, from: 0.6, to: 1)))
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// `progress` remapped so that `from`…`to` is 0…1.
    private static func window(_ progress: Double, from: Double, to: Double) -> Double {
        guard to > from else { return 1 }
        return min(1, max(0, (progress - from) / (to - from)))
    }
}

/// Text typing itself out with a block cursor, `progress` of the way through. It takes the space
/// of the whole string from the start, so nothing reflows, and exposes the whole string to
/// VoiceOver. Under collapsed sequences it is simply the text.
struct TeletypeText: View {
    let text: String
    let progress: Double
    var font: Font = .body
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let characters = Array(text)
        let shown = policy.collapsesSequences
            ? characters.count
            : Int((min(max(progress, 0), 1) * Double(characters.count)).rounded(.down))
        let isTyping = shown < characters.count
        let typed = String(characters.prefix(shown)) + (isTyping ? "▮" : "")
        Text(text)
            .font(font)
            .hidden()
            .overlay(alignment: .topLeading) {
                Text(typed)
                    .font(font)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}
