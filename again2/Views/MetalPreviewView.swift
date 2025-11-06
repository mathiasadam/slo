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
        
        // Use aspect fill to fill the constrained 2:3 view
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
            
            // Calculate aspect-fill scaling (crop to fit view)
            let viewWidth = drawable.texture.width
            let viewHeight = drawable.texture.height
            let imageAspect = Float(width) / Float(height)
            let viewAspect = Float(viewWidth) / Float(viewHeight)
            
            // Calculate source region to crop
            var sourceX = 0
            var sourceY = 0
            var sourceWidth = width
            var sourceHeight = height
            
            if imageAspect > viewAspect {
                // Image is wider than view - crop left/right sides
                sourceWidth = Int(Float(height) * viewAspect)
                sourceX = (width - sourceWidth) / 2
            } else {
                // Image is taller than view - crop top/bottom
                sourceHeight = Int(Float(width) / viewAspect)
                sourceY = (height - sourceHeight) / 2
            }
            
            // Ensure source region is within bounds
            sourceX = max(0, min(sourceX, width - 1))
            sourceY = max(0, min(sourceY, height - 1))
            sourceWidth = min(sourceWidth, width - sourceX)
            sourceHeight = min(sourceHeight, height - sourceY)
            
            // Blit (copy) from cropped source to full drawable
            blitEncoder.copy(
                from: sourceTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: sourceX, y: sourceY, z: 0),
                sourceSize: MTLSize(width: sourceWidth, height: sourceHeight, depth: 1),
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

