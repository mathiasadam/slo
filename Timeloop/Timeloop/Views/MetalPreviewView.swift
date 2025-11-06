import SwiftUI
import MetalKit

/// SwiftUI view that displays processed camera frames with LUT applied
struct MetalPreviewView: UIViewRepresentable {
    let pixelBuffer: CVPixelBuffer?
    
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.framebufferOnly = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        
        // Match screen content mode
        mtkView.contentMode = .scaleAspectFill
        mtkView.contentScaleFactor = UIScreen.main.scale
        
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.pixelBuffer = pixelBuffer
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        var pixelBuffer: CVPixelBuffer?
        private var textureCache: CVMetalTextureCache?
        private var commandQueue: MTLCommandQueue?
        
        override init() {
            super.init()
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle size changes if needed
        }
        
        func draw(in view: MTKView) {
            guard let pixelBuffer = pixelBuffer,
                  let device = view.device,
                  let drawable = view.currentDrawable,
                  let commandBuffer = getCommandQueue(for: device).makeCommandBuffer() else {
                return
            }
            
            // Create texture cache if needed
            if textureCache == nil {
                var cache: CVMetalTextureCache?
                CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                textureCache = cache
            }
            
            guard let textureCache = textureCache else { return }
            
            // Convert pixel buffer to Metal texture
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            
            var cvMetalTexture: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
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
            
            guard let metalTexture = cvMetalTexture,
                  let sourceTexture = CVMetalTextureGetTexture(metalTexture) else {
                return
            }
            
            // Create render pass to blit texture to drawable
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                return
            }
            
            // Calculate aspect-fill scaling
            let viewWidth = drawable.texture.width
            let viewHeight = drawable.texture.height
            let imageAspect = Float(width) / Float(height)
            let viewAspect = Float(viewWidth) / Float(viewHeight)
            
            var sourceRegion: MTLRegion
            if imageAspect > viewAspect {
                // Image is wider - crop sides
                let cropWidth = Int(Float(height) * viewAspect)
                let cropX = (width - cropWidth) / 2
                sourceRegion = MTLRegionMake2D(cropX, 0, cropWidth, height)
            } else {
                // Image is taller - crop top/bottom
                let cropHeight = Int(Float(width) / viewAspect)
                let cropY = (height - cropHeight) / 2
                sourceRegion = MTLRegionMake2D(0, cropY, width, cropHeight)
            }
            
            // Blit (copy) from source to drawable
            blitEncoder.copy(
                from: sourceTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: sourceRegion.origin.x, y: sourceRegion.origin.y, z: 0),
                sourceSize: MTLSize(width: sourceRegion.size.width, height: sourceRegion.size.height, depth: 1),
                to: drawable.texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            
            blitEncoder.endEncoding()
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
        
        private func getCommandQueue(for device: MTLDevice) -> MTLCommandQueue {
            if commandQueue == nil {
                commandQueue = device.makeCommandQueue()
            }
            return commandQueue!
        }
    }
}

