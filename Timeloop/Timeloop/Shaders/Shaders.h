#ifndef Shaders_h
#define Shaders_h

#include <simd/simd.h>

// Vertex input structure
typedef struct {
    simd_float2 position;
    simd_float2 texCoord;
} VertexIn;

// Vertex output structure (to fragment shader)
typedef struct {
    simd_float4 position [[position]];
    simd_float2 texCoord;
} VertexOut;

#endif /* Shaders_h */

