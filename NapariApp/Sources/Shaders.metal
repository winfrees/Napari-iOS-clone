#include <metal_stdlib>
using namespace metal;

// Must match `LayerUniforms` in Renderer.swift.
struct LayerUniforms {
    float2 scale;   // data coordinates -> clip space
    float2 offset;
    float2 size;    // plane width, height in pixels
    float climLow;
    float climHigh;
    float gamma;
    float opacity;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// One quad per layer covering data coordinates (0, 0) to (width, height),
// drawn as a 4-vertex triangle strip.
vertex VertexOut quad_vertex(uint vid [[vertex_id]], constant LayerUniforms &u [[buffer(0)]]) {
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    VertexOut out;
    out.position = float4(corner * u.size * u.scale + u.offset, 0.0, 1.0);
    out.uv = corner;
    return out;
}

// Outputs premultiplied alpha; the blend state decides how it combines with the layers below.
fragment float4 image_fragment(VertexOut in [[stage_in]],
                               texture2d<float> slice [[texture(0)]],
                               texture2d<float> lut [[texture(1)]],
                               sampler sliceSampler [[sampler(0)]],
                               constant LayerUniforms &u [[buffer(0)]]) {
    constexpr sampler lutSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    float value = slice.sample(sliceSampler, in.uv).r;
    float t = clamp((value - u.climLow) / max(u.climHigh - u.climLow, 1e-20f), 0.0f, 1.0f);
    t = pow(t, u.gamma);
    float4 color = lut.sample(lutSampler, float2(t, 0.5));
    float alpha = color.a * u.opacity;
    return float4(color.rgb * alpha, alpha);
}

// Mirrors RGBA.hsv in Colormap.swift.
static float3 hsv2rgb(float h, float s, float v) {
    float3 k = fmod(float3(5.0, 3.0, 1.0) + h * 6.0, float3(6.0));
    return v - v * s * clamp(min(k, 4.0 - k), float3(0.0), float3(1.0));
}

// Mirrors LabelsLayer.color(for:).
static float4 labelColor(uint label) {
    if (label == 0) {
        return float4(0.0);
    }
    float hue = fract(float(label) * 0.618034);
    return float4(hsv2rgb(hue, 0.75, 1.0), 1.0);
}

fragment float4 labels_fragment(VertexOut in [[stage_in]],
                                texture2d<uint> labels [[texture(0)]],
                                constant LayerUniforms &u [[buffer(0)]]) {
    uint2 pixel = uint2(clamp(in.uv * u.size, float2(0.0), u.size - 1.0));
    float4 color = labelColor(labels.read(pixel).r);
    float alpha = color.a * u.opacity;
    return float4(color.rgb * alpha, alpha);
}
