#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
#include <SwiftUI/SwiftUI_Metal.h>   // SwiftUI::Layer, for layerEffect
using namespace metal;

// The app's SwiftUI shaders. Each is reached from Swift through ShaderLibrary.default (see
// ShaderEffects.swift); the Metal compiler builds this file into the app's default library.
//
// Nothing here compiles before CI, so it is written plainly: floats for every calculation (half only
// where SwiftUI hands colours in and out), no templates, no texture sampling beyond a layer effect's
// `layer.sample`, and every helper a static function in this file. `time` is seconds on a clock that
// ShaderEffects folds into a 1000 s cycle; every rate below is a whole number of thousandths of a
// hertz, so nothing jumps at the fold.

constant float kTwoPi = 6.28318530718;

/// Replaces a view's colour with `tint`, keeping its shape. A check that the shader pipeline works.
[[ stitchable ]] half4 probeTint(float2 position, half4 color, half4 tint) {
    return half4(tint.rgb * color.a, color.a);
}

// MARK: - Shared

/// Holds a premultiplied colour under the water's luminance ceiling (motion spec 1.3: relative
/// luminance at most 0.23, so the splash dot, the flames and the reticle keep their contrast over the
/// brightest water). It only ever darkens, and leaves the alpha alone.
static inline float3 capLuminance(float3 rgb, float alpha) {
    float a = max(alpha, 0.001);
    float3 straight = clamp(rgb / a, float3(0.0), float3(1.0));
    float3 lit = pow(straight, float3(2.2));
    float luminance = dot(lit, float3(0.2126, 0.7152, 0.0722));
    if (luminance > 0.225) {
        return rgb * pow(0.225 / luminance, 1.0 / 2.2);
    }
    return rgb;
}

/// 1 on the ring at `radius`, falling smoothly to 0 `halfWidth` away on either side.
static inline float ringBand(float dist, float radius, float halfWidth) {
    return 1.0 - smoothstep(0.0, halfWidth, fabs(dist - radius));
}

// MARK: - oceanWater

/// Living water: a colorEffect over the board's gradient fill. Two slow swell bands run along the
/// diagonal, a finer caustic term plays light over them and its peaks glint; `seaState` (0 calm to 1
/// rough) scales it all, from about ±4 % with faint glints to ±9 % with darker troughs and wind
/// streaks. The result never exceeds the input × 1.18 + 0.02, never exceeds the luminance cap, and
/// keeps the input's premultiplied alpha.
[[ stitchable ]] half4 oceanWater(float2 position, half4 color, float time, float2 size, float seaState) {
    float4 c = float4(color);
    float sea = clamp(seaState, 0.0, 1.0);
    float side = max(max(size.x, size.y), 1.0);
    float2 uv = position / side;

    // The swell: two sines along the top-left to bottom-right diagonal, the longer one with a period
    // of about 0.9 of the water's side, drifting opposite ways.
    float along = (uv.x + uv.y) * 0.70710678;
    float across = (uv.x - uv.y) * 0.70710678;
    float swell = 0.6 * sin(kTwoPi * (along / 0.9 - fract(time * 0.08)))
                + 0.4 * sin(kTwoPi * (along / 0.53 + 0.35 * across + fract(time * 0.05)) + 1.3);

    // Light on the water: three warped waves, multiplied so only their crossings are bright.
    float t1 = fract(time * 0.17);
    float t2 = fract(time * 0.13);
    float t3 = fract(time * 0.11);
    float2 p = uv * 9.0;
    float w1 = 0.5 + 0.5 * sin(kTwoPi * (p.x * 0.71 + 0.31 * sin(kTwoPi * (p.y * 0.37 + t2)) + t1));
    float w2 = 0.5 + 0.5 * sin(kTwoPi * (p.y * 0.83 - 0.27 * sin(kTwoPi * (p.x * 0.41 - t3)) - t2));
    float w3 = 0.5 + 0.5 * sin(kTwoPi * (0.57 * (p.x - p.y) + 0.23 * sin(kTwoPi * (p.x * 0.19 + p.y * 0.29 + t1)) + t3));
    float caustic = w1 * w2 * w3;
    float glint = pow(caustic, 6.0);

    // Rough water: deeper troughs, and wind streaks along the crests.
    float trough = sea * 0.035 * max(-swell, 0.0);
    float streakWave = 0.5 + 0.5 * sin(kTwoPi * (across * 14.0 + 0.5 * along + fract(time * 0.07)));
    float streak = sea * 0.04 * max(swell, 0.0) * (pow(streakWave, 8.0) - 0.15);

    float swellAmount = 0.04 + 0.05 * sea;
    float causticAmount = 0.03 + 0.05 * sea;
    float glintAmount = 0.02 + 0.08 * sea;
    float brightness = 1.0
        + swellAmount * swell
        + causticAmount * (caustic - 0.125) * 2.0
        + glintAmount * glint
        - trough
        + streak;
    brightness = clamp(brightness, 0.8, 1.18);

    float3 rgb = c.rgb * brightness;
    rgb = min(rgb, c.rgb * 1.18 + 0.02 * c.a);
    rgb = min(rgb, float3(c.a));
    rgb = capLuminance(rgb, c.a);
    return half4(float4(rgb, c.a));
}

// MARK: - rippleDistort

/// One impact's pull on the picture at `position`. `impact` is (x, y, start, kind): the centre in
/// points, the birth time in seconds and the kind (0 none, 1 splash, 2 hit). A ring travels out from
/// the centre for 1.3 s, fading as it goes; a hit's ring is stronger and faster than a splash's.
static inline float2 rippleShift(float2 position, float time, float cell, float4 impact) {
    if (impact.w < 0.5) {
        return float2(0.0, 0.0);
    }
    float age = time - impact.z;
    if (age < 0.0 || age > 1.3) {
        return float2(0.0, 0.0);
    }
    float isHit = step(1.5, impact.w);
    float speed = mix(1.6, 2.2, isHit);        // cells a second
    float strength = mix(0.12, 0.17, isHit);   // cells, when the ring is born
    float fade = 1.0 - age / 1.3;
    float radius = cell * (0.3 + speed * age);
    float2 away = position - impact.xy;
    float dist = length(away);
    float band = ringBand(dist, radius, cell * 0.25);
    float amount = cell * strength * fade * band;
    float2 direction = (dist > 0.001) ? (away / dist) : float2(0.0, 0.0);
    return direction * amount;
}

/// Ripples: a distortionEffect for the water. Returns the source position to sample, the pixel's own
/// position pulled back toward each live impact's ring, so the picture bulges outward along the ring.
/// The pull is held to 0.2 cells in all, and the result stays inside the view, so `maxSampleOffset`
/// can be 0.2 cells on each axis.
[[ stitchable ]] float2 rippleDistort(float2 position, float time, float2 size, float cell,
                                      float4 impactA, float4 impactB, float4 impactC, float4 impactD) {
    float unit = max(cell, 1.0);
    float2 shift = rippleShift(position, time, unit, impactA)
                 + rippleShift(position, time, unit, impactB)
                 + rippleShift(position, time, unit, impactC)
                 + rippleShift(position, time, unit, impactD);
    float limit = unit * 0.2;
    float amount = length(shift);
    if (amount > limit) {
        shift = shift * (limit / amount);
    }
    return clamp(position - shift, float2(0.0, 0.0), size);
}

// MARK: - stainWash

/// The darkening of one oil stain at `position`. `stain` is (x, y, start, strength); strength is
/// above 0 for oil. A soft, slightly uneven disc grows from 0.4 to 0.9 cells over two seconds and
/// then holds, at 25 % for a strength of 1.
static inline float oilDarkening(float2 position, float time, float cell, float4 stain) {
    if (stain.w <= 0.0) {
        return 0.0;
    }
    float age = time - stain.z;
    if (age < 0.0) {
        return 0.0;
    }
    float growth = clamp(age / 2.0, 0.0, 1.0);
    growth = growth * (2.0 - growth);
    float2 away = position - stain.xy;
    float dist = length(away);
    float angle = (dist > 0.001) ? atan2(away.y, away.x) : 0.0;
    float seed = fract(stain.z * 0.137) * kTwoPi;
    float wobble = 1.0 + 0.1 * sin(angle * 5.0 + seed) + 0.06 * sin(angle * 3.0 - seed);
    float radius = cell * (0.4 + 0.5 * growth) * wobble;
    float disc = 1.0 - smoothstep(radius * 0.45, radius, dist);
    return 0.25 * min(stain.w, 1.0) * disc;
}

/// The lightening of one patch of foam at `position`: strength below 0 is foam, -1 the most. A faint
/// ring spreads from where the shell splashed, paler inside, and fades out over six seconds.
static inline float foamLightening(float2 position, float time, float cell, float4 stain) {
    if (stain.w >= 0.0) {
        return 0.0;
    }
    float age = time - stain.z;
    if (age < 0.0 || age > 6.0) {
        return 0.0;
    }
    float life = age / 6.0;
    float fade = (1.0 - life) * (1.0 - life);
    float radius = cell * (0.3 + 0.35 * sqrt(life));
    float dist = length(position - stain.xy);
    float ring = ringBand(dist, radius, cell * 0.16);
    float inner = 1.0 - smoothstep(0.0, radius, dist);
    return (0.06 * ring + 0.02 * inner) * min(-stain.w, 1.0) * fade;
}

/// Stains: a colorEffect for the water. Darkens it in soft discs where ships burn and lightens it in
/// faint rings where shells splashed, four stains at most, keeping the alpha and the luminance cap.
[[ stitchable ]] half4 stainWash(float2 position, half4 color, float time, float cell,
                                 float4 stainA, float4 stainB, float4 stainC, float4 stainD) {
    float4 c = float4(color);
    float unit = max(cell, 1.0);
    float dark = oilDarkening(position, time, unit, stainA)
               + oilDarkening(position, time, unit, stainB)
               + oilDarkening(position, time, unit, stainC)
               + oilDarkening(position, time, unit, stainD);
    float foam = foamLightening(position, time, unit, stainA)
               + foamLightening(position, time, unit, stainB)
               + foamLightening(position, time, unit, stainC)
               + foamLightening(position, time, unit, stainD);
    dark = min(dark, 0.4);
    foam = min(foam, 0.1);
    float3 rgb = c.rgb * (1.0 - dark);
    rgb = mix(rgb, float3(c.a), foam);
    rgb = capLuminance(rgb, c.a);
    return half4(float4(rgb, c.a));
}

// MARK: - oceanDrift

/// The screen's backdrop on iOS 17 (iOS 18 draws a MeshGradient): a colorEffect that paints three
/// colour bands, `top` through `middle` to `bottom`, blended by height. The middle band's place drifts
/// with two slow sines of `time`, the way the mesh's points do (`sin(time * 0.31) * 0.09` and
/// `cos(time * 0.23) * 0.08` there; here 49 and 37 mHz, whole cycles in the clock's 1000 s fold). The
/// band colours are taken as opaque; the alpha comes from the input, so the view's shape and fades stay.
[[ stitchable ]] half4 oceanDrift(float2 position, half4 color, float time, float2 size,
                                  half4 top, half4 middle, half4 bottom) {
    float4 c = float4(color);
    float4 t = float4(top);
    float4 m = float4(middle);
    float4 b = float4(bottom);
    float2 uv = float2(position.x / max(size.x, 1.0), position.y / max(size.y, 1.0));
    float drift = sin(kTwoPi * fract(time * 0.049)) * 0.09;
    float swell = cos(kTwoPi * fract(time * 0.037)) * 0.08;

    // Where the middle band sits, from the mesh's middle row: 0.45 + swell at the left edge, rising to
    // 0.55 - drift at the right.
    float centre = 0.45 + 0.10 * uv.x + swell * (1.0 - uv.x) - drift * uv.x;
    centre = clamp(centre, 0.2, 0.8);

    float upperT = clamp(uv.y / centre, 0.0, 1.0);
    float lowerT = clamp((uv.y - centre) / (1.0 - centre), 0.0, 1.0);
    float3 upper = mix(t.rgb, m.rgb, upperT);
    float3 lower = mix(m.rgb, b.rgb, lowerT);
    float3 rgb = mix(upper, lower, step(centre, uv.y));
    return half4(float4(rgb * c.a, c.a));
}

// MARK: - chromaticSplit

/// The damage flash's red/cyan split: a layerEffect that takes red from the layer `offset` away, blue
/// from `offset` the other way, and green and alpha from the pixel itself, so every edge fringes red on
/// one side and blue on the other. An offset of 0 returns the layer unchanged. `maxSampleOffset` has
/// to cover `offset`. Outside the layer's own pixels a fringe can carry more colour than alpha, which
/// composites as an additive fringe, as a split should.
[[ stitchable ]] half4 chromaticSplit(float2 position, SwiftUI::Layer layer, float2 offset) {
    half4 centre = layer.sample(position);
    half4 shiftedRed = layer.sample(position + offset);
    half4 shiftedBlue = layer.sample(position - offset);
    return half4(shiftedRed.r, centre.g, shiftedBlue.b, centre.a);
}

// MARK: - rain

/// A hash of a point with whole-number coordinates, 0…1, without trigonometry (so it holds up under
/// fast maths and large inputs): Dave Hoskins' hash without sine.
static inline float hash21(float2 p) {
    float3 q = fract(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
    q = q + dot(q, float3(q.y + 33.33, q.z + 33.33, q.x + 33.33));
    return fract((q.x + q.y) * q.z);
}

/// One layer of rain: cells `cellWidth` by `cellHeight` points, sheared by `wind` and falling at
/// `cellsPerSecond` cells a second, three in four holding one thin streak (`width` points across, 0.45
/// of the cell long) at a hashed place; `seed` tells the layers apart. Returns the streak's coverage at
/// `position`, 0…1. The fall loops with the clock's 1000 s fold, so nothing jumps there.
static inline float rainLayer(float2 position, float time, float wind, float cellWidth, float cellHeight,
                              float cellsPerSecond, float width, float seed) {
    // Lines of constant `xs` lean with the wind; the pattern slides down along them over time.
    float xs = position.x - wind * position.y;
    float ys = position.y - time * cellsPerSecond * cellHeight;
    float column = floor(xs / cellWidth);
    // Columns start at different heights, so streaks don't line up in rows.
    float phase = hash21(float2(column, seed));
    float yc = (ys / cellHeight) + phase;
    float row = floor(yc);
    float fx = (xs / cellWidth) - column;
    float fy = yc - row;
    // The clock folds every 1000 s, which is 1000 × cellsPerSecond rows: the same key on both sides.
    float rowsPerLoop = 1000.0 * cellsPerSecond;
    float key = row - rowsPerLoop * floor(row / rowsPerLoop);
    float2 cell = float2(column, key);

    float across = hash21(cell + float2(seed + 1.0, seed + 2.0));
    float start = hash21(cell + float2(seed + 3.0, seed + 4.0));
    float lit = hash21(cell + float2(seed + 5.0, seed + 6.0));
    // The streak: a thin line kept clear of the cell's sides, running 0.45 of the cell from a hashed
    // start, fading in and out.
    float streakX = 0.15 + 0.7 * across;
    float dx = fabs(fx - streakX) * cellWidth;
    float side = 1.0 - smoothstep(width * 0.25, width, dx);
    float top = 0.5 * start;
    float along = smoothstep(top, top + 0.08, fy) * (1.0 - smoothstep(top + 0.35, top + 0.45, fy));
    float present = step(0.25, lit);
    return side * along * present;
}

/// Rain: a colorEffect for a clear rectangle over the whole screen, which it fills with wind-blown
/// streaks. Two hashed layers (far: 14 × 42 point cells falling at 420 points a second, thinner and
/// fainter; near: 22 × 66 point cells at 792, brighter) give the streaks' coverage, scaled by
/// `density` (0 none … 1 a downpour); `wind` leans them (points sideways for every point of fall:
/// 0.3 is a brisk slant). The result is the input with the premultiplied `tint` laid over it at that
/// coverage: over a clear rectangle, `tint * coverage`. A `density` of 0 returns the input unchanged.
/// `size` is unused.
[[ stitchable ]] half4 rain(float2 position, half4 color, float time, float2 size,
                            float density, float wind, half4 tint) {
    if (density <= 0.0) {
        return color;
    }
    float amount = clamp(density, 0.0, 1.0);
    float farLayer = rainLayer(position, time, wind, 14.0, 42.0, 10.0, 1.0, 1.0);
    float nearLayer = rainLayer(position, time, wind, 22.0, 66.0, 12.0, 1.5, 2.0);
    float coverage = clamp((0.45 * farLayer + 0.7 * nearLayer) * amount, 0.0, 1.0);

    float4 c = float4(color);
    float4 t = float4(tint);
    float cover = coverage * t.a;
    float3 rgb = c.rgb * (1.0 - cover) + t.rgb * coverage;
    float a = c.a * (1.0 - cover) + cover;
    return half4(float4(rgb, a));
}

// MARK: - scanlines

/// Scan lines and a rim shade for radar dishes: a colorEffect that darkens every other point-row by
/// half of `opacity` (rows 0, 2, 4… lit; 1, 3, 5… darker) and shades toward the edges, by distance from
/// the centre, up to 0.45 × `opacity` at the view's edge. The lines hold still: `time` is unused. An
/// `opacity` of 0 returns the input unchanged. The alpha is kept.
[[ stitchable ]] half4 scanlines(float2 position, half4 color, float time, float2 size, float opacity) {
    if (opacity <= 0.0) {
        return color;
    }
    float amount = clamp(opacity, 0.0, 1.0);
    float4 c = float4(color);
    float row = floor(position.y);
    float odd = row - 2.0 * floor(row * 0.5);
    float line = odd * amount * 0.5;

    float2 centre = float2(max(size.x, 1.0) * 0.5, max(size.y, 1.0) * 0.5);
    float2 away = float2((position.x - centre.x) / centre.x, (position.y - centre.y) / centre.y);
    float edge = smoothstep(0.5, 1.0, length(away));
    float rim = edge * amount * 0.45;

    float shade = clamp(1.0 - line - rim, 0.0, 1.0);
    return half4(float4(c.rgb * shade, c.a));
}
