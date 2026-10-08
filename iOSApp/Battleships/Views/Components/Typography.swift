import SwiftUI

extension View {
    /// Wide, heavy lettering for headlines like VICTORY or YOUR TURN. `size` is the size at the
    /// default text size; from there it follows Dynamic Type like the text style nearest in size.
    func displayFont(_ size: CGFloat, weight: Font.Weight = .heavy, monospacedDigits: Bool = false) -> some View {
        modifier(ScaledFont(
            size: size,
            weight: weight,
            design: .default,
            isExpanded: true,
            monospacedDigits: monospacedDigits,
            relativeTo: .nearest(to: size)
        ))
    }

    /// A system font that is `size` points at the default text size and follows Dynamic Type like
    /// `style`, for small labels set heavier or tighter than any text style.
    func scaledFont(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo style: Font.TextStyle
    ) -> some View {
        modifier(ScaledFont(
            size: size,
            weight: weight,
            design: design,
            isExpanded: false,
            monospacedDigits: false,
            relativeTo: style
        ))
    }
}

private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let isExpanded: Bool
    let monospacedDigits: Bool

    init(
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design,
        isExpanded: Bool,
        monospacedDigits: Bool,
        relativeTo style: Font.TextStyle
    ) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
        self.isExpanded = isExpanded
        self.monospacedDigits = monospacedDigits
    }

    func body(content: Content) -> some View {
        var font = Font.system(size: size, weight: weight, design: design)
        if isExpanded {
            font = font.width(.expanded)
        }
        if monospacedDigits {
            font = font.monospacedDigit()
        }
        return content.font(font)
    }
}

extension Font.TextStyle {
    /// The text style whose default size is closest to `size`, so text set at `size` scales like it.
    static func nearest(to size: CGFloat) -> Font.TextStyle {
        let styles: [(style: Font.TextStyle, size: CGFloat)] = [
            (.largeTitle, 34), (.title, 28), (.title2, 22), (.title3, 20), (.body, 17),
            (.callout, 16), (.subheadline, 15), (.footnote, 13), (.caption, 12), (.caption2, 11),
        ]
        let nearest = styles.min { abs($0.size - size) < abs($1.size - size) }
        return nearest?.style ?? .body
    }
}

enum Phrase {
    /// "1 hit", "3 hits".
    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}
