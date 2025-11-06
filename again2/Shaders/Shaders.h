#ifndef Shaders_h
#define Shaders_h

#include <simd/simd.h>

// Vertex input structure
typedef struct {
    simd_float2 position;  // clip-space position
    simd_float2 texCoord;  // base UV in 0..1 (will be remapped by CropUniform)
} VertexIn;

// Vertex output structure (to fragment shader)
typedef struct {
    simd_float4 position [[position]];
    simd_float2 texCoord;
} VertexOut;

// Crop uniform: remaps base 0..1 UVs into a cropped sub-rect of the source texture.
// finalUV = origin + baseUV * size
typedef struct {
    simd_float2 origin; // (u0, v0)
    simd_float2 size;   // (du, dv)
} CropUniform;

#endif /* Shaders_h */
