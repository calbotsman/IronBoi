#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// One Body — the coach's presence. Ported from orb-lab's One Body variant
// (~/AgentBOB/orb-lab/src/variants/one-body.ts): a soft body that breathes at
// rest, leans toward you while you talk, spins its lobes while it thinks and
// swells with each word it speaks. Your syllables rise as droplets and get
// absorbed, tinting it. The person/push-up form is not ported yet.
//
// Drawn with SwiftUI's colorEffect, so it returns premultiplied colour with
// alpha: outside the body the paper behind the view shows through.

// 3D simplex noise (Ashima Arts / Stefan Gustavson, MIT).
static float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float4 permute(float4 x) { return mod289(((x * 34.0) + 1.0) * x); }
static float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

static float snoise(float3 v) {
    const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    const float4 D = float4(0.0, 0.5, 1.0, 2.0);
    float3 i = floor(v + dot(v, C.yyy));
    float3 x0 = v - i + dot(i, C.xxx);
    float3 g = step(x0.yzx, x0.xyz);
    float3 l = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);
    float3 x1 = x0 - i1 + C.xxx;
    float3 x2 = x0 - i2 + C.yyy;
    float3 x3 = x0 - D.yyy;
    i = mod289(i);
    float4 p = permute(permute(permute(i.z + float4(0.0, i1.z, i2.z, 1.0))
        + i.y + float4(0.0, i1.y, i2.y, 1.0))
        + i.x + float4(0.0, i1.x, i2.x, 1.0));
    float n_ = 0.142857142857;
    float3 ns = n_ * D.wyz - D.xzx;
    float4 j = p - 49.0 * floor(p * ns.z * ns.z);
    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);
    float4 x = x_ * ns.x + ns.yyyy;
    float4 y = y_ * ns.x + ns.yyyy;
    float4 h = 1.0 - abs(x) - abs(y);
    float4 b0 = float4(x.xy, y.xy);
    float4 b1 = float4(x.zw, y.zw);
    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, float4(0.0));
    float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
    float3 p0 = float3(a0.xy, h.x);
    float3 p1 = float3(a0.zw, h.y);
    float3 p2 = float3(a1.xy, h.z);
    float3 p3 = float3(a1.zw, h.w);
    float4 norm = taylorInvSqrt(float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
    p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
    float4 m = max(0.6 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
    m = m * m;
    return 42.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

static float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// ── The person: orb-lab's skeleton SDF ───────────────────────────────
// joints[] is 13 × (x, y, radius) in the orb's own space (body centre at 0).

static float bone(float2 p, float3 a, float3 b) {
    float2 ba = b.xy - a.xy;
    float h = clamp(dot(p - a.xy, ba) / max(dot(ba, ba), 0.00001), 0.0, 1.0);
    return length(p - a.xy - ba * h) - mix(a.z, b.z, h);
}

// Continuous rounded limbs: a quadratic curve through the middle joint.
static float limb(float2 p, float3 a, float3 middle, float3 b) {
    float3 control = 2.0 * middle - 0.5 * (a + b);
    float3 previous = a;
    float d = 10.0;
    for (int i = 1; i <= 8; i++) {
        float t = float(i) / 8.0;
        float3 next = mix(mix(a, control, t), mix(control, b, t), t);
        d = min(d, bone(p, previous, next));
        previous = next;
    }
    return d;
}

// Round only the elbow, keeping an upper arm and a planted forearm.
static float arm(float2 p, float3 shoulder, float3 elbowJ, float3 hand) {
    float3 entry = mix(elbowJ, shoulder, 0.30);
    float3 exitPoint = mix(elbowJ, hand, 0.30);
    float d = min(bone(p, shoulder, entry), bone(p, exitPoint, hand));
    float3 previous = entry;
    for (int i = 1; i <= 6; i++) {
        float t = float(i) / 6.0;
        float3 next = mix(mix(entry, elbowJ, t), mix(elbowJ, exitPoint, t), t);
        d = min(d, bone(p, previous, next));
        previous = next;
    }
    return d;
}

static float3 J(device const float *joints, int i) {
    return float3(joints[i * 3], joints[i * 3 + 1], joints[i * 3 + 2]);
}

static float person(float2 p, device const float *joints, thread float &frontArm, thread float &behindArm) {
    float d = length(p - J(joints, 0).xy) - J(joints, 0).z;
    d = smin(d, bone(p, float3(J(joints, 0).xy, 0.105), J(joints, 1)), 0.11);
    d = smin(d, bone(p, J(joints, 1), J(joints, 2)), 0.12);
    d = smin(d, arm(p, J(joints, 3), J(joints, 4), J(joints, 5)), 0.045);
    d = smin(d, limb(p, J(joints, 2), J(joints, 9), J(joints, 10)), 0.085);
    d = smin(d, limb(p, J(joints, 2), J(joints, 11), J(joints, 12)), 0.085);
    behindArm = d;
    frontArm = arm(p, J(joints, 6), J(joints, 7), J(joints, 8));
    return smin(d, frontArm, 0.045);
}

// ── Equipment: shapes the CPU lays out from the hands ──────────────
// gear[] is 8 floats per shape: kind, a.xy, b.xy, r, angle, depth. Kind -1
// is an empty slot; 0 capsule a→b, 1 rounded box at a (half-size b, turned
// by angle), 2 upper half-ring at a (radius b.x, thickness r). Depth 2 is in
// front of everything, 1 in front of the body but under the hands, 0.5
// between the legs (behind the near one), -1 behind the body. Returns the
// field for each layer: (held, behind, front, between).
static float4 gearField(float2 p, device const float *gear, int count) {
    float4 d = float4(10.0);
    for (int i = 0; i + 7 < count; i += 8) {
        float kind = gear[i];
        if (kind < 0.0) continue;
        float2 a = float2(gear[i + 1], gear[i + 2]);
        float2 b = float2(gear[i + 3], gear[i + 4]);
        float r = gear[i + 5];
        float s;
        if (kind < 0.5) {
            s = bone(p, float3(a, r), float3(b, r));
        } else if (kind < 1.5) {
            float c = cos(gear[i + 6]), sn = sin(gear[i + 6]);
            float2 q = float2(c * (p.x - a.x) + sn * (p.y - a.y), -sn * (p.x - a.x) + c * (p.y - a.y));
            float2 e = abs(q) - b + r;
            s = length(max(e, 0.0)) + min(max(e.x, e.y), 0.0) - r;
        } else {
            float c = cos(gear[i + 6]), sn = sin(gear[i + 6]);
            float2 q = float2(c * (p.x - a.x) + sn * (p.y - a.y), -sn * (p.x - a.x) + c * (p.y - a.y));
            float ring = abs(length(q) - b.x) - r;
            // Only the arch above the centre; below it, the distance to the arch's ends.
            s = q.y >= 0.0 ? ring : length(float2(abs(q.x) - b.x, q.y)) - r;
        }
        float depth = gear[i + 7];
        if (depth > 1.5) d.z = min(d.z, s);
        else if (depth > 0.75) d.x = min(d.x, s);
        else if (depth > 0.0) d.w = min(d.w, s);
        else d.y = min(d.y, s);
    }
    return d;
}

static float hash21(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

[[ stitchable ]] half4 oneBody(
    float2 position, half4 color,
    float2 size, float time,
    // squashAxis.xy is the axis, .zw the jelly amplitudes: packed because
    // SwiftUI's function stitching fails past ~26 arguments.
    float radius, float squash, float4 squashAxis, float2 center, float3 lobes,
    float spin, float tint, float fuse, float soft, float glow, float grain,
    half4 bodyColor, half4 youColor,
    device const float *drops, int dropCount,
    device const float *joints, int jointCount,
    float form, float armDepth,
    device const float *gear, int gearCount, float gearBlend
) {
    // Same space as the web version: the short side spans -1…1, y up.
    float2 p = (position - size * 0.5) / min(size.x, size.y) * 2.0;
    p.y = -p.y;

    // Squash along an axis, volume-preserving: `squash` > 1 stretches the
    // body along `squashAxis` (it is moving that way), < 1 flattens it along
    // the axis (it just landed from that direction). A vertical axis is the
    // old behaviour: leaning down toward you flattens it top-to-bottom.
    float2 q0 = p - center;
    float2 ax = normalize(squashAxis.xy);
    float2 jelly = squashAxis.zw;
    float2 q = float2(dot(q0, ax) / squash, (q0.x * ax.y - q0.y * ax.x) * sqrt(squash));
    float a = atan2(q.y, q.x);
    // `spin` is the lobes' rotation, integrated on the CPU. Computing it as
    // time × rate made every rate change (thinking → speaking) jump the angle
    // by time × Δrate — many turns once the app had been open a while.
    // Jelly: two ringing modes anchored to the squash axis — a landing
    // sets the 2-lobe mode going along the way it arrived, a bloop the
    // 3-lobe one. Both are springs on the CPU; this is just their shape.
    float axisAngle = atan2(ax.y, ax.x);
    float lobe = lobes.x * sin(2.0 * a + spin)
               + lobes.y * sin(3.0 * a - spin * 1.3)
               + lobes.z * sin(7.0 * a + spin * 2.1)
               + jelly.x * cos(2.0 * (a - axisAngle))
               + jelly.y * cos(3.0 * (a - axisAngle) + 0.7);
    float d = length(q) - radius * (1.0 + lobe + 0.04 * snoise(float3(q * 2.2, time * 0.4)));

    // A body when it helps: the blob's field blends into the person's.
    float frontArm = 10.0, behindArm = 10.0;
    float2 local = p - center;
    if (form > 0.001 && jointCount >= 39) {
        d = mix(d, person(local, joints, frontArm, behindArm), form);
    }
    // Equipment, grown out of the same material: gooey while it grows out,
    // then its own object, layered in front of or behind the body.
    float bodyD = d;
    float handD = 10.0, nearLegD = 10.0;
    float4 gearD = gearField(local, gear, gearCount);
    if (form > 0.001 && jointCount >= 39) {
        handD = min(length(local - J(joints, 5).xy) - J(joints, 5).z,
                    length(local - J(joints, 8).xy) - J(joints, 8).z);
        if (gearD.w < 1.0) nearLegD = limb(local, J(joints, 2), J(joints, 11), J(joints, 12));
    }
    float anyGear = min(min(gearD.x, gearD.y), min(gearD.z, gearD.w));
    if (anyGear < 1.0) {
        d = smin(d, anyGear, gearBlend);
    }

    // Your syllables: droplets that merge into the body as they arrive.
    float you = 0.0;
    for (int i = 0; i + 3 < dropCount; i += 4) {
        float r = drops[i + 2];
        if (r <= 0.0) continue;
        float dd = length(p - float2(drops[i], drops[i + 1])) - r;
        // h is the body's share of the blend; the droplet's is 1 - h. Your
        // droplets carry your colour and blend into the body where they
        // touch; the body itself tints only as it absorbs them (uTint).
        float h = clamp(0.5 + 0.5 * (dd - d) / fuse, 0.0, 1.0);
        // drops[i+3] is how blue the drop still is: 1 in flight, falling
        // to 0 as it reaches the body, so it's absorbed as amber instead of
        // averaging blue with amber into grey.
        you = max(you, (1.0 - h) * drops[i + 3]);
        d = smin(d, dd, fuse);
    }

    float k = clamp(max(you, tint), 0.0, 1.0);
    float3 c = mix(float3(bodyColor.rgb), float3(youColor.rgb), k);
    // Blue and amber average to grey halfway; lift the midpoint toward a
    // light pastel so a bloop warming into the body never reads as mud.
    c = mix(c, float3(1.0), 4.0 * k * (1.0 - k) * 0.42);
    // Pale centre, soft edge, no dark rim.
    c = mix(c, float3(1.0), (1.0 - smoothstep(-radius, 0.0, d)) * 0.38);
    // Soft contact shading shows the tucked elbow against the torso. It
    // fades out standing and as a blob, and never outlines the silhouette.
    if (armDepth > 0.001) {
        float overlap = (1.0 - smoothstep(-0.025, 0.015, behindArm)) * armDepth;
        float shoulderFade = smoothstep(0.09, 0.22, length(local - J(joints, 6).xy));
        float crease = exp(-pow((frontArm - 0.014) / 0.035, 2.0)) * overlap * shoulderFade;
        c *= 1.0 - crease * 0.08;
        float armFill = 1.0 - smoothstep(-0.035, 0.01, frontArm);
        c = mix(c, mix(c, float3(1.0), 0.055), armFill * overlap * 0.7);
    }
    if (anyGear < 1.0) {
        float e = 0.01;
        float bodyIn = 1.0 - smoothstep(-e, e, bodyD);
        float handIn = 1.0 - smoothstep(-e, e, handD);
        float heldIn = (1.0 - smoothstep(-e, e, gearD.x)) * (1.0 - handIn);
        float frontIn = 1.0 - smoothstep(-e, e, gearD.z);
        float nearLegIn = 1.0 - smoothstep(-e, e, nearLegD);
        float betweenIn = (1.0 - smoothstep(-e, e, gearD.w)) * (1.0 - nearLegIn) * (1.0 - handIn);
        float behindIn = (1.0 - smoothstep(-e, e, gearD.y)) * (1.0 - bodyIn);
        float over = max(max(heldIn, frontIn), betweenIn);
        float gearIn = max(over, behindIn);
        // A soft contact shadow on whatever is underneath, right at the
        // edge of what passes in front of it — that's what reads as depth.
        float nearFront = exp(-max(min(min(gearD.x, gearD.z), gearD.w), 0.0) / 0.018);
        float nearBody = exp(-max(bodyD, 0.0) / 0.018);
        float nearLeg = exp(-max(nearLegD, 0.0) / 0.018);
        float shade = bodyIn * (1.0 - over) * nearFront + behindIn * nearBody
                    + betweenIn * (1.0 - smoothstep(-e, e, gearD.w)) * nearLeg;
        c = mix(c, float3(bodyColor.rgb) * 0.84, gearIn);
        c *= 1.0 - clamp(shade, 0.0, 1.0) * 0.16;
    }
    float edge = soft + form * 0.012;
    float fill = 1.0 - smoothstep(-edge, edge, d);
    float halo = exp(-max(d, 0.0) / max(glow, 0.01)) * 0.3 * (1.0 - fill);
    float alpha = fill * 0.93;
    alpha = alpha + (1.0 - alpha) * halo;

    float g = (hash21(floor(position) + fract(time * 7.0) * 113.0) - 0.5) * grain;
    float3 outColor = clamp(c + g, 0.0, 1.0);
    return half4(half3(outColor * alpha), half(alpha));
}
