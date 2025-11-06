import Foundation
import Metal
import CoreImage
import simd

struct Curve1DBuilder {
    struct ControlPoint {
        let input: Float   // 0..1
        let output: Float  // 0..1
    }
    
    // Build a 1D float curve with given resolution by linear interpolation across control points.
    static func buildCurveSamples(points: [ControlPoint], resolution: Int = 1024) -> [Float] {
        precondition(resolution >= 2)
        guard points.count >= 2 else {
            // Identity if no points
            return (0..<resolution).map { Float($0) / Float(resolution - 1) }
        }
        
        // Ensure points are sorted and clamped
        let sorted = points
            .map { ControlPoint(input: max(0, min(1, $0.input)), output: max(0, min(1, $0.output))) }
            .sorted { $0.input < $1.input }
        
        var samples = [Float](repeating: 0, count: resolution)
        var seg = 0
        
        for i in 0..<resolution {
            let x = Float(i) / Float(resolution - 1)
            
            // Advance segment so that sorted[seg].input <= x <= sorted[seg+1].input
            while seg + 1 < sorted.count - 1 && x > sorted[seg + 1].input {
                seg += 1
            }
            
            let p0 = sorted[seg]
            let p1 = sorted[min(seg + 1, sorted.count - 1)]
            
            if p1.input <= p0.input {
                samples[i] = p0.output
                continue
            }
            let t = (x - p0.input) / (p1.input - p0.input)
            samples[i] = simd_mix(p0.output, p1.output, t)
        }
        
        return samples
    }
    
    // Create a Metal 1D texture with r32Float format from samples
    static func makeMetalTexture(device: MTLDevice, samples: [Float]) -> MTLTexture? {
        let length = samples.count
        let desc = MTLTextureDescriptor()
        desc.textureType = .type1D
        desc.pixelFormat = .r32Float
        desc.width = length
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        samples.withUnsafeBytes { ptr in
            tex.replace(region: MTLRegionMake1D(0, length), mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: length * MemoryLayout<Float>.size)
        }
        return tex
    }
    
    // Create a CIImage (1 x N) from samples (RGBA float, but we will store the curve in R channel)
    static func makeCIImage(samples: [Float]) -> CIImage? {
        let width = samples.count
        var rgba = [Float](repeating: 0, count: width * 4)
        for i in 0..<width {
            let v = max(0, min(1, samples[i]))
            rgba[i * 4 + 0] = v // R
            rgba[i * 4 + 1] = v // G (not needed, but mirror for convenience)
            rgba[i * 4 + 2] = v // B
            rgba[i * 4 + 3] = 1 // A
        }
        guard let data = CFDataCreate(nil, UnsafePointer<UInt8>(OpaquePointer(rgba.withUnsafeBytes { $0.baseAddress! })), rgba.count * MemoryLayout<Float>.size) else {
            return nil
        }
        guard let provider = CGDataProvider(data: data) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgImage = CGImage(width: width,
                                    height: 1,
                                    bitsPerComponent: 32,
                                    bitsPerPixel: 128,
                                    bytesPerRow: width * 16,
                                    space: colorSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent) else {
            return nil
        }
        return CIImage(cgImage: cgImage)
    }
}
