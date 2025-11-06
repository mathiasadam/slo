import Foundation
import Metal
import MetalKit
import CoreVideo
import AVFoundation

class MetalLUTRenderer {
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let lutTexture: MTLTexture
    private let textureCache: CVMetalTextureCache
    private let processingQueue = DispatchQueue(label: "com.slo.metalrendering", qos: .userInteractive)
    
    // Vertex data for full-screen quad
    private let vertices: [Float] = [
        // Position(x,y)  TexCoord(u,v)
        -1.0,  1.0,      0.0, 0.0,  // Top-left
         1.0,  1.0,      1.0, 0.0,  // Top-right
        -1.0, -1.0,      0.0, 1.0,  // Bottom-left
         1.0, -1.0,      1.0, 1.0   // Bottom-right
    ]
    
    private var vertexBuffer: MTLBuffer?
    
    init() throws {
        print("🎨 Initializing MetalLUTRenderer...")
        
        // Get Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRendererError.noMetalDevice
        }
        self.device = device
        print("  Device: \(device.name)")
        
        // Create command queue
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalRendererError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue
        
        // Load LUT texture
        guard let lutURL = Bundle.main.url(forResource: "Fuji_Neopan", withExtension: "cube", subdirectory: "Utilities") ??
                           Bundle.main.url(forResource: "Fuji_Neopan", withExtension: "cube") else {
            throw MetalRendererError.lutFileNotFound
        }
        
        self.lutTexture = try LUTTextureLoader.loadLUTTexture(from: lutURL, device: device)
        
        // Load shaders and create pipeline
        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.shaderLibraryNotFound
        }
        
        guard let vertexFunction = library.makeFunction(name: "vertexShader"),
              let fragmentFunction = library.makeFunction(name: "fragmentShader") else {
            throw MetalRendererError.shaderFunctionNotFound
        }
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        // Create texture cache for CVPixelBuffer conversion
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard result == kCVReturnSuccess, let textureCache = cache else {
            throw MetalRendererError.textureCacheCreationFailed
        }
        self.textureCache = textureCache
        
        // Create vertex buffer
        let vertexDataSize = vertices.count * MemoryLayout<Float>.stride
        guard let buffer = device.makeBuffer(bytes: vertices, length: vertexDataSize, options: []) else {
            throw MetalRendererError.bufferCreationFailed
        }
        self.vertexBuffer = buffer
        
        print("✅ MetalLUTRenderer initialized successfully")
    }
    
    /// Render a pixel buffer with LUT applied
    func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        autoreleasepool {
            // Convert input pixel buffer to Metal texture
            guard let inputTexture = createTexture(from: pixelBuffer) else {
                print("❌ Failed to create input texture")
                return nil
            }
            
            // Create output pixel buffer
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            
            var outputPixelBuffer: CVPixelBuffer?
            let attributes: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &outputPixelBuffer
            )
            
            guard status == kCVReturnSuccess, let outputBuffer = outputPixelBuffer else {
                print("❌ Failed to create output pixel buffer")
                return nil
            }
            
            // Convert output pixel buffer to Metal texture
            guard let outputTexture = createTexture(from: outputBuffer) else {
                print("❌ Failed to create output texture")
                return nil
            }
            
            // Create render pass
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = outputTexture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            
            // Execute rendering
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                print("❌ Failed to create command buffer or encoder")
                return nil
            }
            
            renderEncoder.setRenderPipelineState(pipelineState)
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            renderEncoder.setFragmentTexture(inputTexture, index: 0)
            renderEncoder.setFragmentTexture(lutTexture, index: 1)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()
            
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            
            return outputBuffer
        }
    }
    
    /// Create Metal texture from CVPixelBuffer
    private func createTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var cvMetalTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvMetalTexture
        )
        
        guard result == kCVReturnSuccess, let metalTexture = cvMetalTexture else {
            return nil
        }
        
        return CVMetalTextureGetTexture(metalTexture)
    }
}

enum MetalRendererError: Error, LocalizedError {
    case noMetalDevice
    case commandQueueCreationFailed
    case lutFileNotFound
    case shaderLibraryNotFound
    case shaderFunctionNotFound
    case textureCacheCreationFailed
    case bufferCreationFailed
    
    var errorDescription: String? {
        switch self {
        case .noMetalDevice:
            return "Metal is not available on this device"
        case .commandQueueCreationFailed:
            return "Failed to create Metal command queue"
        case .lutFileNotFound:
            return "LUT cube file not found in bundle"
        case .shaderLibraryNotFound:
            return "Metal shader library not found"
        case .shaderFunctionNotFound:
            return "Shader functions not found in library"
        case .textureCacheCreationFailed:
            return "Failed to create CVMetalTextureCache"
        case .bufferCreationFailed:
            return "Failed to create Metal buffer"
        }
    }
}

