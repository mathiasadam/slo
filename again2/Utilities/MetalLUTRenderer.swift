import Foundation
import Metal
import MetalKit
import CoreVideo
import AVFoundation
import simd

class MetalLUTRenderer {
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let lutTexture: MTLTexture
    private let curveTexture: MTLTexture
    private let textureCache: CVMetalTextureCache
    private let processingQueue = DispatchQueue(label: "com.slo.metalrendering", qos: .userInitiated)
    
    // Dynamic vertex buffer
    private var vertexBuffer: MTLBuffer?
    // Density uniform buffer
    private var densityBuffer: MTLBuffer?
    // Grain uniform buffer
    private var grainBuffer: MTLBuffer?
    // Vignette uniform buffer
    private var vignetteBuffer: MTLBuffer?
    
    // Fixed 3:4 output pool
    private var pixelBufferPool: CVPixelBufferPool?
    private let targetWidth: Int
    private let targetHeight: Int
    
    // Density params struct mirrors Metal
    struct DensityParams {
        var densityGamma: Float
        var pad: SIMD3<Float> = .zero
    }
    private var density = DensityParams(densityGamma: 1.10) // can be overridden from CameraManager
    
    // Grain params struct mirrors Metal
    struct GrainParams {
        var intensity: Float        // 0..1, typical 0.03..0.15
        var size: Float             // spatial frequency; 1.0..3.0 typical
        var seed: Float             // base seed (changed per frame for animated grain)
        var animationSpeed: Float   // multiplier for time evolution (0 = static)
        var filmResponseStrength: Float // 0..1, how much to modulate by film response
        var chromaStrength: Float       // 0..1, subtle chroma tint in grain
        var pad: SIMD2<Float> = .zero   // align to 32 bytes
    }
    private var grain = GrainParams(
        intensity: 0.0,  // Disabled - no film grain
        size: 1.75,
        seed: 0.0,
        animationSpeed: 1.0,
        filmResponseStrength: 0.8,
        chromaStrength: 0.15
    )
    private var frameCounter: UInt64 = 0
    
    // Vignette params struct mirrors Metal
    struct VignetteParams {
        var intensity: Float   // 0..1
        var radius: Float      // 0..1
        var softness: Float    // 0..1
        var roundness: Float   // 0..1
        var center: SIMD2<Float> // 0..1
        var pad: SIMD2<Float> = .zero
    }
    private var vignette = VignetteParams(
        intensity: 0.35,
        radius: 0.85,
        softness: 0.45,
        roundness: 0.2,
        center: SIMD2<Float>(0.5, 0.5)
    )
    
    init(targetWidth: Int = 1080, targetHeight: Int = 1440) throws {
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        
        print("🎨 Initializing MetalLUTRenderer (target \(targetWidth)x\(targetHeight))...")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRendererError.noMetalDevice
        }
        self.device = device
        print("  Device: \(device.name)")
        
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalRendererError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue
        
        // Load LUT texture (3D)
        guard let lutURL = Bundle.main.url(forResource: "Fuji_Neopan", withExtension: "cube", subdirectory: "Utilities") ??
                           Bundle.main.url(forResource: "Fuji_Neopan", withExtension: "cube") else {
            throw MetalRendererError.lutFileNotFound
        }
        self.lutTexture = try LUTTextureLoader.loadLUTTexture(from: lutURL, device: device)
        
        // Build 1D tone curve from your 10-point control set -> samples -> 1D texture
        let customPoints: [Curve1DBuilder.ControlPoint] = [
            .init(input: 0.0000, output: 0.0000),
            .init(input: 0.0913, output: 0.0658),
            .init(input: 0.1984, output: 0.1139),
            .init(input: 0.2738, output: 0.1973),
            .init(input: 0.4531, output: 0.3957),
            .init(input: 0.5770, output: 0.6399),
            .init(input: 0.7568, output: 0.8378),
            .init(input: 0.8295, output: 0.9178),
            .init(input: 0.9334, output: 0.9612),
            .init(input: 1.0000, output: 1.0000)
        ]
        let samples = Curve1DBuilder.buildCurveSamples(points: customPoints, resolution: 1024)
        guard let curveTex = Curve1DBuilder.makeMetalTexture(device: device, samples: samples) else {
            throw MetalRendererError.textureCacheCreationFailed
        }
        self.curveTexture = curveTex
        
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
        
        // Texture cache
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard result == kCVReturnSuccess, let textureCache = cache else {
            throw MetalRendererError.textureCacheCreationFailed
        }
        self.textureCache = textureCache
        
        // Create initial vertex buffer
        self.vertexBuffer = makeVertexBuffer(cropU: 0, cropV: 0, cropWidth: 1, cropHeight: 1)
        
        // Create density buffer
        let len = MemoryLayout<DensityParams>.stride
        densityBuffer = device.makeBuffer(length: len, options: .storageModeShared)
        if let buf = densityBuffer {
            var d = density
            memcpy(buf.contents(), &d, len)
        }
        
        // Create grain buffer
        let glen = MemoryLayout<GrainParams>.stride
        grainBuffer = device.makeBuffer(length: glen, options: .storageModeShared)
        if let gb = grainBuffer {
            var g = grain
            memcpy(gb.contents(), &g, glen)
        }
        
        // Create vignette buffer
        let vlen = MemoryLayout<VignetteParams>.stride
        vignetteBuffer = device.makeBuffer(length: vlen, options: .storageModeShared)
        if let vb = vignetteBuffer {
            var v = vignette
            memcpy(vb.contents(), &v, vlen)
        }
        
        // Create fixed-size pool for 3:4 output
        createPixelBufferPool(width: targetWidth, height: targetHeight)

        // Prime the pool aggressively to avoid first-frame hiccups
        primePixelBufferPool(minimumBufferCount: 16)
        
        print("✅ MetalLUTRenderer initialized for 3:4 output (with custom 1D tone curve + density + vignette)")
    }
    
    // Optional API to tweak darkness
    func setDensityGamma(_ gamma: Float) {
        density.densityGamma = max(0.1, gamma)
        if let buf = densityBuffer {
            var d = density
            memcpy(buf.contents(), &d, MemoryLayout<DensityParams>.stride)
        }
    }
    
    // Grain configuration APIs
    func setGrain(intensity: Float? = nil, size: Float? = nil, animationSpeed: Float? = nil) {
        if let i = intensity { grain.intensity = max(0.0, min(1.0, i)) }
        if let s = size { grain.size = max(0.5, min(6.0, s)) }
        if let a = animationSpeed { grain.animationSpeed = max(0.0, a) }
        updateGrainBuffer()
    }
    
    func setGrainFilmResponse(strength: Float? = nil, chromaStrength: Float? = nil) {
        if let fr = strength { grain.filmResponseStrength = max(0.0, min(1.0, fr)) }
        if let cs = chromaStrength { grain.chromaStrength = max(0.0, min(1.0, cs)) }
        updateGrainBuffer()
    }
    
    private func updateGrainBuffer() {
        guard let gb = grainBuffer else { return }
        var g = grain
        memcpy(gb.contents(), &g, MemoryLayout<GrainParams>.stride)
    }
    
    // Vignette configuration APIs
    func setVignette(intensity: Float? = nil, radius: Float? = nil, softness: Float? = nil, roundness: Float? = nil, center: SIMD2<Float>? = nil) {
        if let i = intensity { vignette.intensity = max(0.0, min(1.0, i)) }
        if let r = radius { vignette.radius = max(0.0, min(1.0, r)) }
        if let s = softness { vignette.softness = max(0.0, min(1.0, s)) }
        if let ro = roundness { vignette.roundness = max(0.0, min(1.0, ro)) }
        if let c = center { vignette.center = SIMD2<Float>(max(0, min(1, c.x)), max(0, min(1, c.y))) }
        updateVignetteBuffer()
    }
    
    private func updateVignetteBuffer() {
        guard let vb = vignetteBuffer else { return }
        var v = vignette
        memcpy(vb.contents(), &v, MemoryLayout<VignetteParams>.stride)
    }
    
    // New: Asynchronous render that calls completion after GPU work is finished
    func render(pixelBuffer: CVPixelBuffer, completion: @escaping (_ outputBuffer: CVPixelBuffer) -> Void) {
        autoreleasepool {
            guard let inputTexture = createTexture(from: pixelBuffer) else { return }
            
            // Aspect-fill crop calculation
            let srcWidth = Float(inputTexture.width)
            let srcHeight = Float(inputTexture.height)
            let srcAspect = srcWidth / srcHeight
            let tgtAspect = Float(targetWidth) / Float(targetHeight)
            
            var u0: Float = 0, v0: Float = 0, uSize: Float = 1, vSize: Float = 1
            if srcAspect > tgtAspect {
                let neededWidth = tgtAspect * srcHeight
                let cropWidth = neededWidth / srcWidth
                u0 = (1 - cropWidth) * 0.5
                uSize = cropWidth
                v0 = 0
                vSize = 1
            } else {
                let neededHeight = srcWidth / tgtAspect
                let cropHeight = neededHeight / srcHeight
                v0 = (1 - cropHeight) * 0.5
                vSize = cropHeight
                u0 = 0
                uSize = 1
            }
            self.vertexBuffer = makeVertexBuffer(cropU: u0, cropV: v0, cropWidth: uSize, cropHeight: vSize)
            
            guard let outputBuffer = getOutputPixelBuffer(),
                  let outputTexture = createTexture(from: outputBuffer) else { return }
            
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = outputTexture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            
            // Update grain seed per frame for animated grain
            frameCounter &+= 1
            if grain.animationSpeed > 0 {
                let base = Float((frameCounter % 10_000)) * grain.animationSpeed
                grain.seed = base
                updateGrainBuffer()
            }
            
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }
            
            renderEncoder.setRenderPipelineState(pipelineState)
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            renderEncoder.setFragmentTexture(inputTexture, index: 0)
            renderEncoder.setFragmentTexture(lutTexture, index: 1)
            renderEncoder.setFragmentTexture(curveTexture, index: 2)
            if let db = densityBuffer {
                renderEncoder.setFragmentBuffer(db, offset: 0, index: 1)
            }
            if let gb = grainBuffer {
                renderEncoder.setFragmentBuffer(gb, offset: 0, index: 2)
            }
            if let vb = vignetteBuffer {
                renderEncoder.setFragmentBuffer(vb, offset: 0, index: 3)
            }
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()
            
            // Call completion only after GPU has finished writing into outputBuffer
            commandBuffer.addCompletedHandler { _ in
                completion(outputBuffer)
            }
            commandBuffer.commit()
        }
    }
    
    // MARK: - Helpers
    
    private func createPixelBufferPool(width: Int, height: Int) {
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        if status == kCVReturnSuccess {
            pixelBufferPool = pool
        } else {
            pixelBufferPool = nil
            print("❌ Failed to create pixel buffer pool for \(width)x\(height)")
        }
    }
    
    private func primePixelBufferPool(minimumBufferCount: Int) {
        guard let pool = pixelBufferPool else { return }
        var temp: [CVPixelBuffer] = []
        temp.reserveCapacity(minimumBufferCount)
        for _ in 0..<minimumBufferCount {
            var pb: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
            if status == kCVReturnSuccess, let p = pb {
                temp.append(p)
            }
        }
        // Let them deallocate; the pool is now warmed up
        temp.removeAll()
    }
    
    private func getOutputPixelBuffer() -> CVPixelBuffer? {
        guard let pool = pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess else {
            return nil
        }
        return pixelBuffer
    }
    
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
    
    // Create/update a vertex buffer with positions and cropped texCoords
    private func makeVertexBuffer(cropU: Float, cropV: Float, cropWidth: Float, cropHeight: Float) -> MTLBuffer? {
        // Vertex layout: [pos.x, pos.y, tex.u, tex.v]
        let vertices: [Float] = [
            -1.0,  1.0,        cropU,               cropV,                // top-left
             1.0,  1.0,        cropU + cropWidth,   cropV,                // top-right
            -1.0, -1.0,        cropU,               cropV + cropHeight,   // bottom-left
             1.0, -1.0,        cropU + cropWidth,   cropV + cropHeight    // bottom-right
        ]
        let length = vertices.count * MemoryLayout<Float>.stride
        return device.makeBuffer(bytes: vertices, length: length, options: [])
    }
}

enum MetalRendererError: Error, LocalizedError {
    case noMetalDevice
    case commandQueueCreationFailed
    case lutFileNotFound
    case shaderLibraryNotFound
    case shaderFunctionNotFound
    case textureCacheCreationFailed
    
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
        }
    }
}
