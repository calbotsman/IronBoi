#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The workout screen as weather. One full-screen colorEffect pass over the
// paper, driven by `effort` (0 calm … 1 pumping, already eased over ~10 s
// on the CPU — see Effort.swift).
//
//   calm     a soft, flat lift of the paper itself: brighter, lower
//            contrast, almost no colour; fine, sparse grain that changes
//            slowly.
//   pumping  a warm glow where MYO stands, falling off to deeper, richer
//            colour at the edges: darker, higher contrast, more colour;
//            denser, coarser grain that changes faster.
//
// The two must read apart without hue (docs/product/ideas.md, "Works
// without colour"), so every step that adds colour also moves luminance
// and contrast, and grain density changes on its own.
//
// Cost per pixel: two integer hashes, one length, a handful of mixes. No
// texture reads, no loops.

static float hash21(float2 p, float seed) {
    // Integer-style hash (Dave Hoskins, "Hash without Sine", MIT): stable
    // on mobile GPUs, no visible lattice at these scales.
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973) + seed * 0.1237);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

[[ stitchable ]] half4 workoutAtmosphere(
    float2 position, half4 color,
    float2 size,
    float time,        // seconds; frozen under Reduce Motion
    float effort,      // 0…1
    half4 paper,       // the paper colour underneath
    half4 warm,        // the coach's colour
    half4 ink,         // the paper's ink, for grain
    float dark         // 1 on a dark paper
) {
    float e = clamp(effort, 0.0, 1.0);
    // Ease the ends so the middle of the range does most of the moving:
    // a set at moderate effort already looks different from rest.
    float ee = e * e * (3.0 - 2.0 * e);

    // Distance from where MYO stands (the stage's focus, 42% down),
    // measured in half-widths, squashed vertically so the glow is a tall
    // oval and the bottom controls sit in the falloff, not the dark.
    float2 focus = float2(0.5 * size.x, 0.42 * size.y);
    float2 p = (position - focus) / (0.5 * min(size.x, size.y));
    p.y *= 0.62;
    float r = length(p);

    float3 base = float3(paper.rgb);
    float3 hue = float3(warm.rgb);

    // Calm: the paper, lifted and flattened. Toward white on a light
    // paper; on a dark one a small lift of the paper itself.
    float3 lifted = dark > 0.5 ? base * 1.35 + 0.035 : mix(base, float3(1.0), 0.55);
    float3 calm = lifted;
    float calmAlpha = 0.55;

    // Pumping: a warm glow at the centre falling to deep colour at the edge.
    // Squaring the hue deepens its saturation (amber → ember) without a
    // hue shift, so a custom coach colour stays itself.
    float3 rich = mix(hue, hue * hue, 0.5);
    float3 glow = dark > 0.5 ? mix(base, hue, 0.42) * 1.15 : mix(hue, float3(1.0), 0.66);
    float3 deep = dark > 0.5 ? base * 0.35 + rich * 0.12 : rich * 0.8;
    float edge = smoothstep(0.30, 1.55, r);
    float3 pumped = mix(glow, deep, edge * edge * (3.0 - 2.0 * edge));
    float pumpedAlpha = mix(0.78, 0.9, edge);

    float3 col = mix(calm, pumped, ee);
    float alpha = mix(calmAlpha, pumpedAlpha, ee);

    // Grain. Cell size in points: fine at rest, coarser when pumping.
    // Re-seeded on a clock that speeds up with effort (6 → 24 Hz), so it
    // looks like it moves faster rather than just being louder.
    float cell = mix(0.55, 1.1, ee);
    float2 cellId = floor(position / cell);
    float frame = floor(time * mix(6.0, 24.0, ee));
    float n = hash21(cellId, frame);
    float density = mix(0.04, 0.26, ee);
    float strength = mix(0.10, 0.19, ee) * (0.6 + 0.4 * hash21(cellId + 17.0, frame));
    float speck = step(1.0 - density, n) * strength;
    col = mix(col, float3(ink.rgb), speck);
    alpha = alpha + (1.0 - alpha) * speck;

    return half4(half3(col * alpha), half(alpha));
}
