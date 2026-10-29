import SwiftUI

/// The shaders in Shaders.metal, as SwiftUI effects.
enum ShaderEffects {
    /// Paints the view's opaque pixels in one colour.
    static func tint(_ color: Color) -> Shader {
        ShaderLibrary.default.probeTint(.color(color))
    }
}
