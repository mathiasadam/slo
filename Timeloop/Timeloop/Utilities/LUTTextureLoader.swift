import Foundation
import Metal
import Accelerate

class LUTTextureLoader {
    
    /// Load a 3D LUT texture from a .cube file
    static func loadLUTTexture(from url: URL, device: MTLDevice) throws -> MTLTexture {
        print("🎨 Loading LUT texture from: \(url.lastPathComponent)")
        
        // Parse the cube file
        let (lutData, dimension) = try LUTParser.parseCubeFile(at: url)
        
        print("  LUT dimension: \(dimension)x\(dimension)x\(dimension)")
        print("  Data size: \(lutData.count) bytes")
        
        // Create Metal texture descriptor for 3D texture
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.textureType = .type3D
        textureDescriptor.pixelFormat = .rgba16Float
        textureDescriptor.width = dimension
        textureDescriptor.height = dimension
        textureDescriptor.depth = dimension
        textureDescriptor.usage = [.shaderRead]
        textureDescriptor.storageMode = .shared
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw LUTTextureError.textureCreationFailed
        }
        
        // Convert Float data to Float16 for Metal
        let float32Array = lutData.withUnsafeBytes { ptr -> [Float] in
            Array(ptr.bindMemory(to: Float.self))
        }
        
        // Metal expects RGBA, our LUT parser already added alpha = 1.0
        let totalValues = dimension * dimension * dimension * 4
        guard float32Array.count == totalValues else {
            throw LUTTextureError.invalidDataSize(expected: totalValues, got: float32Array.count)
        }
        
        // Convert to Float16 (Metal's rgba16Float format)
        var float16Array = [UInt16]()
        float16Array.reserveCapacity(float32Array.count)
        
        for value in float32Array {
            float16Array.append(floatToFloat16(value))
        }
        
        // Upload data to texture
        let bytesPerRow = dimension * 4 * MemoryLayout<UInt16>.size
        let bytesPerImage = bytesPerRow * dimension
        
        float16Array.withUnsafeBytes { ptr in
            let region = MTLRegionMake3D(0, 0, 0, dimension, dimension, dimension)
            texture.replace(region: region,
                          mipmapLevel: 0,
                          slice: 0,
                          withBytes: ptr.baseAddress!,
                          bytesPerRow: bytesPerRow,
                          bytesPerImage: bytesPerImage)
        }
        
        print("✅ LUT texture created successfully")
        
        return texture
    }
    
    /// Convert Float32 to Float16 (half precision)
    private static func floatToFloat16(_ value: Float) -> UInt16 {
        var f32 = value
        var f16: UInt16 = 0
        
        withUnsafePointer(to: &f32) { f32Ptr in
            withUnsafeMutablePointer(to: &f16) { f16Ptr in
                var sourceBuffer = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: f32Ptr),
                    height: 1,
                    width: 1,
                    rowBytes: 4
                )
                var destBuffer = vImage_Buffer(
                    data: UnsafeMutableRawPointer(f16Ptr),
                    height: 1,
                    width: 1,
                    rowBytes: 2
                )
                vImageConvert_PlanarFtoPlanar16F(&sourceBuffer, &destBuffer, 0)
            }
        }
        
        return f16
    }
}

enum LUTTextureError: Error, LocalizedError {
    case textureCreationFailed
    case invalidDataSize(expected: Int, got: Int)
    
    var errorDescription: String? {
        switch self {
        case .textureCreationFailed:
            return "Failed to create Metal texture"
        case .invalidDataSize(let expected, let got):
            return "Invalid LUT data size: expected \(expected) values, got \(got)"
        }
    }
}

