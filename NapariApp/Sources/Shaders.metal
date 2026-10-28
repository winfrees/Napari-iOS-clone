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

// MARK: - 3D volume rendering

// Must match `VolumeUniforms` in Renderer.swift.
struct VolumeUniforms {
    float4x4 cameraToWorld; // camera (right, down, forward) axes and the volume centre, in voxels
    float4 volumeSize;      // width, height, depth in voxels
    float2 viewSize;        // points
    float2 pan;             // points
    float zoom;             // points per voxel
    float climLow;          // contrast limits, normalised to the texture's 0...1 range
    float climHigh;
    float gamma;
    float opacity;
    uint mode;              // 0 MIP, 1 MinIP, 2 average
};

// A quad covering the whole view; uv (0, 0) is the top-left corner.
vertex VertexOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    VertexOut out;
    out.position = float4(corner.x * 2.0 - 1.0, 1.0 - corner.y * 2.0, 0.0, 1.0);
    out.uv = corner;
    return out;
}

// Orthographic ray casting: each pixel marches one ray through the volume,
// about one sample per voxel, and projects the samples to a single value.
fragment float4 volume_fragment(VertexOut in [[stage_in]],
                                texture3d<float> volume [[texture(0)]],
                                texture2d<float> lut [[texture(1)]],
                                constant VolumeUniforms &u [[buffer(0)]]) {
    constexpr sampler volumeSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    constexpr sampler lutSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    float2 camera = (in.uv * u.viewSize - 0.5 * u.viewSize - u.pan) / u.zoom;
    float3 origin = (u.cameraToWorld * float4(camera, 0.0, 1.0)).xyz;
    float3 direction = (u.cameraToWorld * float4(0.0, 0.0, 1.0, 0.0)).xyz;
    float3 size = u.volumeSize.xyz;

    // Slab test against the box [0, size]. Avoid dividing by zero for axis-aligned rays.
    float3 safe = select(direction, float3(1e-6), abs(direction) < 1e-6);
    float3 t0 = -origin / safe;
    float3 t1 = (size - origin) / safe;
    float3 tMin = min(t0, t1);
    float3 tMax = max(t0, t1);
    float tNear = max(max(tMin.x, tMin.y), tMin.z);
    float tFar = min(min(tMax.x, tMax.y), tMax.z);
    if (tFar <= tNear) {
        discard_fragment();
    }

    int steps = clamp(int(ceil(tFar - tNear)), 1, 2048);
    float dt = (tFar - tNear) / float(steps);
    float projected = u.mode == 1 ? 1.0f : 0.0f;
    for (int i = 0; i < steps; i++) {
        float3 p = origin + direction * (tNear + (float(i) + 0.5) * dt);
        float value = volume.sample(volumeSampler, p / size).r;
        if (u.mode == 0) {
            projected = max(projected, value);
        } else if (u.mode == 1) {
            projected = min(projected, value);
        } else {
            projected += value;
        }
    }
    if (u.mode == 2) {
        projected /= float(steps);
    }

    float t = clamp((projected - u.climLow) / max(u.climHigh - u.climLow, 1e-6f), 0.0f, 1.0f);
    t = pow(t, u.gamma);
    float4 color = lut.sample(lutSampler, float2(t, 0.5));
    float alpha = color.a * u.opacity;
    return float4(color.rgb * alpha, alpha);
}

// MARK: - Points

// Must match `PointInstance` in Renderer.swift.
struct PointInstance {
    float2 center;      // data (x, y)
    float size;         // diameter in data pixels
    float borderWidth;  // fraction of the radius
    float4 face;
    float4 border;
};

struct PointOut {
    float4 position [[position]];
    float2 local;       // -1...1 across the point
    float borderWidth [[flat]];
    float4 face [[flat]];
    float4 border [[flat]];
};

// One quad per point instance, sized in data pixels so points scale with zoom like napari.
vertex PointOut points_vertex(uint vid [[vertex_id]],
                              uint iid [[instance_id]],
                              constant LayerUniforms &u [[buffer(0)]],
                              const device PointInstance *points [[buffer(1)]]) {
    PointInstance p = points[iid];
    float2 corner = float2(float(vid & 1), float(vid >> 1)) * 2.0 - 1.0;
    float2 data = p.center + corner * 0.5 * p.size;
    PointOut out;
    out.position = float4(data * u.scale + u.offset, 0.0, 1.0);
    out.local = corner;
    out.borderWidth = p.borderWidth;
    out.face = p.face;
    out.border = p.border;
    return out;
}

// A disc with a border ring, antialiased over about one screen pixel.
fragment float4 points_fragment(PointOut in [[stage_in]], constant LayerUniforms &u [[buffer(0)]]) {
    float r = length(in.local);
    float aa = max(fwidth(r), 1e-4f);
    float coverage = 1.0 - smoothstep(1.0 - aa, 1.0, r);
    if (coverage <= 0.0) {
        discard_fragment();
    }
    float inBorder = smoothstep(1.0 - in.borderWidth - aa, 1.0 - in.borderWidth, r);
    float4 color = mix(in.face, in.border, inBorder);
    float alpha = color.a * coverage * u.opacity;
    return float4(color.rgb * alpha, alpha);
}

// MARK: - Shapes

// Must match `ShapeVertex` in Renderer.swift. Fills, edges and handles are all
// pre-built triangles in data coordinates.
struct ShapeVertex {
    float2 position;
    float4 color;
};

struct ShapeOut {
    float4 position [[position]];
    float4 color;
};

vertex ShapeOut shapes_vertex(uint vid [[vertex_id]],
                              constant LayerUniforms &u [[buffer(0)]],
                              const device ShapeVertex *vertices [[buffer(1)]]) {
    ShapeVertex v = vertices[vid];
    ShapeOut out;
    out.position = float4(v.position * u.scale + u.offset, 0.0, 1.0);
    out.color = v.color;
    return out;
}

fragment float4 shapes_fragment(ShapeOut in [[stage_in]], constant LayerUniforms &u [[buffer(0)]]) {
    float alpha = in.color.a * u.opacity;
    return float4(in.color.rgb * alpha, alpha);
}
