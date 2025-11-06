#include <metal_stdlib>
#include <simd/simd.h>
#include "Shaders.h"

using namespace metal;

// Small fragment uniform for post-curve density (gamma-like darken)
struct DensityParams {
    float densityGamma; // 1.0 = neutral, >1.0 = darker, <1.0 = brighter
    float3 pad;
};

// Grain parameters
// If you later extend with blendMode and blendFactor, keep layout-compatible by appending at the end.
struct GrainParams {
    float intensity;            // 0..1
    float size;                 // spatial frequency (lower => finer with our mapping)
    float seed;                 // animated seed (CPU-updated slowly)
    float animationSpeed;       // not used directly here; CPU updates seed
    float filmResponseStrength; // 0..1
    float chromaStrength;       // 0..1
    // Optional future fields:
    // int   blendMode;         // 0=Overlay, 1=SoftLight, 2=Multiply, 3=LinearLight
    // float blendFactor;       // typical 0.04 for Overlay/SoftLight
    float2 pad;
};

// Vignette parameters
struct VignetteParams {
    float intensity;   // 0..1, strength of darkening
    float radius;      // 0..1, where falloff begins from center
    float softness;    // 0..1, width of falloff
    float roundness;   // 0..1, 0 = fit aspect ellipse, 1 = circle
    float2 center;     // 0..1 center in UV
    float2 pad;
};

// Vertex shader - simple passthrough for full-screen quad
vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                               constant VertexIn *vertices [[buffer(0)]]) {
    VertexOut out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.texCoord = vertices[vertexID].texCoord;
    return out;
}

// Hash-based value noise: fast, tile-friendly
inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

// Smooth value noise at a given frequency
inline float valueNoise(float2 uv, float freq, float seed) {
    float2 p = uv * freq + seed;
    float2 i = floor(p);
    float2 f = fract(p);
    
    float a = hash21(i + float2(0.0, 0.0));
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Film-like temporal phase mixing: blend two phases to avoid pulsing
inline float temporalPhase(float baseSeed, float channelJitter) {
    float phaseA = baseSeed * (0.0071 + channelJitter);
    float phaseB = (baseSeed + 37.0) * (0.0093 + channelJitter * 0.5);
    float w = fract(baseSeed * 0.0031 + channelJitter * 13.1);
    return mix(phaseA, phaseB, w);
}

// Film-grain function blending multi-frequency noise (tuned for finer grain)
inline float filmGrainMono(float2 uv, float seed, float sizeParam) {
    float sizeClamped = clamp(sizeParam, 0.5, 3.0);
    float baseFreq = 220.0 / sizeClamped;
    float hiFreq   = 380.0 / sizeClamped;
    float loFreq   = 120.0 / sizeClamped;
    
    float phase = temporalPhase(seed, 0.0);
    
    float nLo = valueNoise(uv, loFreq,  phase * 0.61);
    float n1  = valueNoise(uv, baseFreq, phase * 0.73);
    float n2  = valueNoise(uv, hiFreq,   phase * 1.37);
    
    float n = (n1 * 0.62 + n2 * 0.34 + nLo * 0.04);
    return (n - 0.5); // −0.5..+0.5
}

inline float3 filmGrainChroma(float2 uv, float seed, float sizeParam) {
    float phaseR = temporalPhase(seed, 0.11);
    float phaseG = temporalPhase(seed, 0.23);
    float phaseB = temporalPhase(seed, 0.37);
    
    float r = filmGrainMono(uv, phaseR, sizeParam);
    float g = filmGrainMono(uv, phaseG, sizeParam);
    float b = filmGrainMono(uv, phaseB, sizeParam);
    return float3(r, g, b);
}

// Response curve shaping: stronger in midtones, weaker in deep shadows/highlights
inline float responseWeight(float3 curvedRGB) {
    float luma = dot(curvedRGB, float3(0.299, 0.587, 0.114));
    float mid = smoothstep(0.08, 0.55, luma) * (1.0 - smoothstep(0.55, 0.98, luma));
    float shadowBoost = smoothstep(0.02, 0.12, luma) * 0.35;
    return clamp(mid + shadowBoost, 0.0, 1.0);
}

// Blend helpers (inputs in 0..1)
inline float blendOverlay(float base, float blend) {
    return (base < 0.5) ? (2.0 * base * blend) : (1.0 - 2.0 * (1.0 - base) * (1.0 - blend));
}
inline float blendSoftLight(float base, float blend) {
    return (blend < 0.5)
        ? (base - (1.0 - 2.0 * blend) * base * (1.0 - base))
        : (base + (2.0 * blend - 1.0) * (sqrt(base) - base));
}
inline float blendMultiply(float base, float blend) {
    return base * blend;
}
inline float blendLinearLight(float base, float blend) {
    return clamp(base + (2.0 * blend - 1.0), 0.0, 1.0);
}

// Vignette mask (0 at center, up to 1 at edges)
// roundness: 0 -> fit aspect ellipse, 1 -> circle
inline float vignetteMask(float2 uv, constant VignetteParams& v) {
    float2 centered = uv - v.center;
    float aspect = 3.0 / 4.0; // matches renderer target aspect
    float2 scaleEllipse = float2(mix(aspect, 1.0, v.roundness), mix(1.0 / aspect, 1.0, v.roundness));
    float2 p = centered * scaleEllipse;

    // Stronger bias outward to strengthen mask
    float dist = length(p) * 1.12;

    // Make falloff start earlier and be steeper
    float start = v.radius * 0.95; // earlier
    float end = clamp(start + max(1e-4, v.softness) * 0.75, 0.0, 2.0); // narrower
    float t = smoothstep(start, end, dist);
    return t; // 0 center, 1 outer
}

// Fragment shader - applies 3D LUT, 1D curve, density, grain, then vignette
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                texture2d<float> cameraTexture [[texture(0)]],
                                texture3d<float> lutTexture [[texture(1)]],
                                texture1d<float> curveTexture [[texture(2)]],
                                constant DensityParams& density [[buffer(1)]],
                                constant GrainParams& grain [[buffer(2)]],
                                constant VignetteParams& vignette [[buffer(3)]]) {
    constexpr sampler textureSampler(mag_filter::linear,
                                     min_filter::linear,
                                     address::clamp_to_edge);
    
    // Sample the camera frame
    float4 originalColor = cameraTexture.sample(textureSampler, in.texCoord);
    
    // 3D LUT (RGB -> RGB)
    float3 lutCoord = originalColor.rgb;
    float3 lutRGB = lutTexture.sample(textureSampler, lutCoord).rgb;
    
    // Apply 1D tone curve per channel (pre-density)
    float r = curveTexture.sample(textureSampler, lutRGB.r).r;
    float g = curveTexture.sample(textureSampler, lutRGB.g).r;
    float b = curveTexture.sample(textureSampler, lutRGB.b).r;
    float3 curved = clamp(float3(r, g, b), 0.0, 1.0);
    
    // Post-curve density (gamma-like darkening)
    float gamma = max(0.001, density.densityGamma);
    float3 baseRGB = pow(curved, float3(gamma));
    
    // Film-response-modulated grain
    if (grain.intensity > 0.0001) {
        float2 uv = in.texCoord * max(grain.size, 0.001);
        float resp = responseWeight(curved);
        float mod = mix(1.0, resp, clamp(grain.filmResponseStrength, 0.0, 1.0));
        
        float mono = filmGrainMono(uv, grain.seed, grain.size) * (grain.intensity * mod);
        float3 chroma = filmGrainChroma(uv, grain.seed, grain.size) * (grain.intensity * mod * grain.chromaStrength);
        float3 grainRGB = float3(mono) + chroma * 0.30;
        
        float3 blendTex = clamp(grainRGB + 0.5, 0.0, 1.0);
        
        const float factor = 0.04;
        float3 overlayed = float3(
            blendOverlay(baseRGB.r, blendTex.r),
            blendOverlay(baseRGB.g, blendTex.g),
            blendOverlay(baseRGB.b, blendTex.b)
        );
        baseRGB = mix(baseRGB, overlayed, factor);
    }
    
    // Vignette darkening (further boosted visibility)
    if (vignette.intensity > 0.0001) {
        float mask = vignetteMask(in.texCoord, vignette); // 0 center -> 1 edge
        const float visibilityBoost = 2.5; // increased
        float strength = clamp(vignette.intensity * visibilityBoost, 0.0, 1.0);
        baseRGB *= (1.0 - strength * mask);
    }
    
    return float4(clamp(baseRGB, 0.0, 1.0), originalColor.a);
}
