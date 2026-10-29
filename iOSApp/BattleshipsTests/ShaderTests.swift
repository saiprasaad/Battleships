#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit
@testable import Battleships

/// The Metal shaders have to be compiled into the app and run on the simulator; these draw each one and
/// read pixels back, which is the only way to know without a device in hand.
@MainActor
@Suite("Shaders", .serialized)
struct ShaderTests {
    @Test func shadersCompileAndRun() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(
            rootView: Color.white
                .frame(width: 120, height: 120)
                .colorEffect(ShaderEffects.tint(Color(red: 1, green: 0, blue: 0)))
        )
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        window.isHidden = true
        let pixel = try #require(Self.pixel(at: CGPoint(x: 60, y: 60), in: image))
        // Pure red, not Color.red: the system red is #FF453A in the dark appearance.
        #expect(pixel.red > 0.9 && pixel.green < 0.15 && pixel.blue < 0.15, "expected red, got \(pixel)")
    }

    /// `oceanWater` only modulates the water: on the brightest water, at its roughest, no pixel goes over
    /// the luminance cap (motion spec 1.3), and over time it averages out to the colour it was given,
    /// not a tint.
    @Test func oceanWaterModulatesUnderTheLuminanceCap() async throws {
        let size = CGSize(width: 120, height: 120)
        let plainImage = try await Self.render(Theme.seaGlow, settle: .milliseconds(250))
        let plain = try #require(Self.pixel(at: CGPoint(x: 60, y: 60), in: plainImage))
        let plainLuminance = Self.relativeLuminance(plain)
        #expect(plainLuminance < 0.23, "the brightest water, seaGlow, has to start under the cap: \(plain)")

        let lattice: [CGFloat] = [12, 36, 60, 84, 108]
        var luminances: [Double] = []
        var totals = (red: 0.0, green: 0.0, blue: 0.0)
        for (index, time) in [0.0, 1.3, 2.9, 4.4, 6.1, 7.7, 9.2, 10.8].enumerated() {
            let image = try await Self.render(
                Theme.seaGlow.colorEffect(ShaderEffects.water(time: time, size: size, seaState: 1)),
                settle: .milliseconds(index == 0 ? 600 : 150)
            )
            for y in lattice {
                for x in lattice {
                    let sample = try #require(Self.pixel(at: CGPoint(x: x, y: y), in: image))
                    let luminance = Self.relativeLuminance(sample)
                    #expect(luminance <= 0.23, "at \(time) s, (\(x), \(y)) is \(sample): luminance \(luminance)")
                    luminances.append(luminance)
                    totals.red += sample.red
                    totals.green += sample.green
                    totals.blue += sample.blue
                }
            }
        }

        let count = Double(luminances.count)
        let meanLuminance = luminances.reduce(0, +) / count
        #expect(abs(meanLuminance - plainLuminance) < 0.06 * plainLuminance, "mean luminance \(meanLuminance) drifted from \(plainLuminance)")
        // One 8-bit level of slack on top of the 6 %, for rounding.
        #expect(abs(totals.red / count - plain.red) < 0.06 * plain.red + 0.004, "mean red \(totals.red / count) drifted from \(plain.red)")
        #expect(abs(totals.green / count - plain.green) < 0.06 * plain.green + 0.004, "mean green \(totals.green / count) drifted from \(plain.green)")
        #expect(abs(totals.blue / count - plain.blue) < 0.06 * plain.blue + 0.004, "mean blue \(totals.blue / count) drifted from \(plain.blue)")
    }

    /// `rippleDistort` bends the water on the ring and nowhere else.
    @Test func rippleDistortBendsTheWaterOnTheRing() async throws {
        let size = CGSize(width: 120, height: 120)
        let cell: CGFloat = 20
        let age: TimeInterval = 0.3
        let time: TimeInterval = 100
        // White to the left of x = 60, black to the right.
        let fill = HStack(spacing: 0) {
            Color.white
            Color.black
        }
        let plain = try await Self.render(fill, settle: .milliseconds(250))

        // A ring centred on the split couldn't move it (it crosses the split straight on), so the hit
        // lands one ring radius to the left: the ring reaches the split travelling straight right and
        // pulls white water under the first black pixels.
        let radius = WaterImpact.ringRadius(of: .hit, at: age, cell: cell)
        let impact = WaterImpact(x: 60 - radius, y: 60, start: time - age, kind: .hit)
        let bent = try await Self.render(
            fill.distortionEffect(
                ShaderEffects.ripples(time: time, size: size, cell: cell, impacts: [impact]),
                maxSampleOffset: CGSize(width: cell * 0.2, height: cell * 0.2)
            ),
            settle: .milliseconds(600)
        )

        let edge = CGPoint(x: 61, y: 60)
        let plainEdge = try #require(Self.pixel(at: edge, in: plain))
        let bentEdge = try #require(Self.pixel(at: edge, in: bent))
        #expect(plainEdge.red < 0.2, "expected black just right of the split, got \(plainEdge)")
        #expect(bentEdge.red > 0.6, "expected the ring to pull white water over \(edge), got \(bentEdge)")
        for point in [CGPoint(x: 8, y: 8), CGPoint(x: 112, y: 112), CGPoint(x: 61, y: 8)] {
            let before = try #require(Self.pixel(at: point, in: plain))
            let after = try #require(Self.pixel(at: point, in: bent))
            #expect(abs(before.red - after.red) < 0.05 && abs(before.blue - after.blue) < 0.05, "\(point) changed from \(before) to \(after)")
        }
    }

    /// `stainWash` darkens the water under an oil stain and leaves the rest alone.
    @Test func stainWashDarkensUnderAStain() async throws {
        let time: TimeInterval = 50
        let stain = WaterStain(x: 60, y: 60, start: time - WaterStain.growth, strength: 1)
        let image = try await Self.render(
            Theme.seaTop.colorEffect(ShaderEffects.stains(time: time, cell: 30, stains: [stain])),
            settle: .milliseconds(600)
        )
        let centre = try #require(Self.pixel(at: CGPoint(x: 60, y: 60), in: image))
        let corner = try #require(Self.pixel(at: CGPoint(x: 8, y: 8), in: image))
        let centreLuminance = Self.relativeLuminance(centre)
        let cornerLuminance = Self.relativeLuminance(corner)
        #expect(centreLuminance < cornerLuminance * 0.85, "the centre \(centre) should be darker than the corner \(corner)")
        #expect(corner.blue > 0.4 && corner.blue > corner.red, "the corner should still be sea, got \(corner)")
    }

    /// `WaterView` puts the three passes together and still shows the sea.
    @Test func waterViewRendersTheSea() async throws {
        let geometry = BoardGeometry(boardSize: 10, side: 120, showsLabels: false)
        let now = Date().timeIntervalSinceReferenceDate
        let water = WaterView(
            geometry: geometry,
            seaState: 0.6,
            impacts: [WaterImpact(x: 60, y: 60, start: now, kind: .splash)],
            stains: [
                WaterStain(x: 30, y: 30, start: now - 3, strength: 1),
                WaterStain(x: 90, y: 90, start: now - 1, strength: -1),
            ]
        )
        let image = try await Self.render(water, settle: .milliseconds(700))
        let centre = try #require(Self.pixel(at: CGPoint(x: 60, y: 60), in: image))
        #expect(centre.blue > 0.2 && centre.blue > centre.red, "expected sea at the centre, got \(centre)")
        let stained = try #require(Self.pixel(at: CGPoint(x: 30, y: 30), in: image))
        #expect(stained.red + stained.green + stained.blue > 0.05, "the stain should darken the water, not black it out, got \(stained)")
    }

    /// Shows `view` in a 120×120 window, gives it `settle` to draw, and takes its picture, as the probe
    /// does. If the picture is still blank at `landmark` (a point every view here paints), it waits a
    /// little longer, twice at most, so a slow first frame doesn't fail a test.
    private static func render(_ view: some View, settle: Duration, landmark: CGPoint = CGPoint(x: 30, y: 60)) async throws -> UIImage {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: view.frame(width: 120, height: 120))
        window.makeKeyAndVisible()
        try await Task.sleep(for: settle)

        var image = Self.snapshot(window)
        var retries = 0
        while retries < 2, Self.isBlank(image, at: landmark) {
            try await Task.sleep(for: .milliseconds(250))
            image = Self.snapshot(window)
            retries += 1
        }
        window.isHidden = true
        return image
    }

    private static func snapshot(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    /// Whether nothing has been drawn at `point` yet.
    private static func isBlank(_ image: UIImage, at point: CGPoint) -> Bool {
        guard let sample = pixel(at: point, in: image) else { return true }
        return sample.red + sample.green + sample.blue < 0.05
    }

    /// The relative luminance of an sRGB pixel (WCAG), which the motion spec's cap is measured in.
    private static func relativeLuminance(_ pixel: (red: Double, green: Double, blue: Double)) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(pixel.red) + 0.7152 * linear(pixel.green) + 0.0722 * linear(pixel.blue)
    }

    /// The colour at `point` (in points), or nil if the image can't be read.
    private static func pixel(at point: CGPoint, in image: UIImage) -> (red: Double, green: Double, blue: Double)? {
        guard let cgImage = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let scale = image.scale
        context.draw(cgImage, in: CGRect(x: -point.x * scale, y: -(image.size.height - point.y) * scale, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
    }
}
#endif
