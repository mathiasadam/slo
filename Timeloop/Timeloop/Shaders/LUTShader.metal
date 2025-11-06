#include <metal_stdlib>
#include <simd/simd.h>
#include "Shaders.h"

using namespace metal;

// Vertex shader - simple passthrough for full-screen quad
vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                               constant VertexIn *vertices [[buffer(0)]]) {
    VertexOut out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.texCoord = vertices[vertexID].texCoord;
    return out;
}

// Fragment shader - applies 3D LUT to camera frame
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                texture2d<float> cameraTexture [[texture(0)]],
                                texture3d<float> lutTexture [[texture(1)]]) {
    constexpr sampler textureSampler(mag_filter::linear,
                                     min_filter::linear,
                                     address::clamp_to_edge);
    
    // Sample the camera frame
    float4 originalColor = cameraTexture.sample(textureSampler, in.texCoord);
    
    // Use RGB as 3D coordinates to sample the LUT
    // LUT cube maps input RGB to output RGB
    float3 lutCoord = originalColor.rgb;
    
    // Sample the 3D LUT texture
    float4 lutColor = lutTexture.sample(textureSampler, lutCoord);
    
    // Return the color-graded pixel, preserve alpha
    return float4(lutColor.rgb, originalColor.a);
}

