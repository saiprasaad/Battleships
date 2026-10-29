#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit
@testable import Battleships

/// The Metal shaders have to be compiled into the app and run on the simulator; this draws one and
/// reads a pixel back, which is the only way to know without a device in hand.
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
                .colorEffect(ShaderEffects.tint(.red))
        )
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        window.isHidden = true
        let pixel = try #require(Self.pixel(at: CGPoint(x: 60, y: 60), in: image))
        #expect(pixel.red > 0.9 && pixel.green < 0.1 && pixel.blue < 0.1, "expected red, got \(pixel)")
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
