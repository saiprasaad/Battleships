#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// The app's SwiftUI shaders. Each is reached from Swift through ShaderLibrary.default (see
// ShaderEffects.swift); the Metal compiler builds this file into the app's default library.

/// Replaces a view's colour with `tint`, keeping its shape. A check that the shader pipeline works.
[[ stitchable ]] half4 probeTint(float2 position, half4 color, half4 tint) {
    return half4(tint.rgb * color.a, color.a);
}
