import AVFoundation
import SwiftUI
import Combine
import VideoToolbox

enum RecordingState: Equatable {
    case idle
    case preparing
    case recording
    case failed(String)
}

class CameraManager: NSObject, ObservableObject {
    @Published var isAuthorized = false
    @Published var isRecording = false
    @Published var isWarmedUp = false // True when pipeline and encoder are ready
    @Published var recordingState: RecordingState = .idle
    @Published var session = AVCaptureSession()
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    var useRealtimeProcessing = true // Always real-time capture path
    @Published var currentCameraPosition: AVCaptureDevice.Position = .back
    
    // Capture I/O
    private var videoDataOutput = AVCaptureVideoDataOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    
    // Recording: real-time GPU LUT + writer
    private var metalRenderer: MetalLUTRenderer?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    // Queues
    private let captureQueue = DispatchQueue(label: "com.slo.capture", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "com.slo.camera.session")
    private let recordingRenderQueue = DispatchQueue(label: "com.slo.recording.render", qos: .userInitiated)
    
    // Timing / counters
    private var recordingStartTime: CMTime?
    private var frameCount = 0
    private var inflightRecordingRenders = 0
    private let maxInflightRecordingRenders = 6 // Increased to handle 120fps bursts
    private var recordingStopTimer: DispatchSourceTimer?
    private var isFinishingRecording = false // Guard against multiple finish calls
    
    // Progress / UI
    @Published var recordingProgress: Double = 0.0
    @Published var processedVideoURL: URL?
    
    // Output size calculated dynamically from camera format (3:4 portrait aspect)
    private var outputWidth = 1080
    private var outputHeight = 1440

    // Super-resolution upscaling (disabled for smaller file sizes for messaging)
    private let superResolutionScale: Double = 1.0  // No upscaling for messaging compatibility
    private var upscaledWidth: Int { Int(Double(outputWidth) * superResolutionScale) }
    private var upscaledHeight: Int { Int(Double(outputHeight) * superResolutionScale) }
    private var pixelTransferSession: VTPixelTransferSession?
    private var superResolutionPoolAdaptor: CVPixelBufferPool?

    // Frame rate conversion for slow motion
    private let sourceFPS: Double = 120.0  // Capture frame rate
    private let targetFPS: Double = 30.0   // Output playback frame rate (4x slow motion)
    private let slowMotionFactor: Double = 4.0  // sourceFPS / targetFPS

    // Frame rate conversion tracking
    private var frameRateConversionStartTime: CMTime?
    private var convertedFrameCount: Int64 = 0
    
    override init() {
        super.init()
        // Metal renderer will be initialized after camera setup with proper dimensions
    }
    
    // MARK: - Metal Renderer Initialization

    private func initializeMetalRenderer(width: Int, height: Int) {
        guard metalRenderer == nil else { return }
        do {
            self.metalRenderer = try MetalLUTRenderer(targetWidth: width, targetHeight: height)
            self.metalRenderer?.setDensityGamma(1.06)
            print("✅ Metal renderer initialized - real-time processing at \(width)x\(height)")
            self.useRealtimeProcessing = true
        } catch {
            print("⚠️ Metal renderer failed to initialize: \(error.localizedDescription)")
            self.useRealtimeProcessing = false
        }
    }

    // MARK: - Super-Resolution Setup

    private func setupSuperResolution() {
        // Create pixel transfer session
        var session: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)

        guard status == noErr, let transferSession = session else {
            print("⚠️ Failed to create VTPixelTransferSession: \(status)")
            return
        }

        // Configure super-resolution scaler (iOS 18+)
        // Note: VTLowLatencySuperResolutionScaler is enabled automatically when upscaling
        // by setting appropriate destination size larger than source

        // Enable high-quality scaling mode
        let scalingModeKey = kVTPixelTransferPropertyKey_ScalingMode
        let scalingModeValue = kVTScalingMode_Trim // High quality bicubic scaling

        VTSessionSetProperty(
            transferSession,
            key: scalingModeKey,
            value: scalingModeValue
        )

        // On iOS 18+, VideoToolbox can use ML super-resolution automatically
        // when the scale factor is appropriate (typically 2x or 4x)
        if #available(iOS 18.0, *) {
            print("✅ Super-resolution scaler enabled (2x upscaling: \(outputWidth)x\(outputHeight) → \(upscaledWidth)x\(upscaledHeight))")
            print("  📱 iOS 18+ ML super-resolution will be applied automatically")
        } else {
            print("✅ High-quality bicubic scaler configured (2x upscaling: \(outputWidth)x\(outputHeight) → \(upscaledWidth)x\(upscaledHeight))")
        }

        self.pixelTransferSession = transferSession

        // Create pixel buffer pool for upscaled output
        createSuperResolutionPool()
    }

    private func createSuperResolutionPool() {
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: upscaledWidth,
            kCVPixelBufferHeightKey as String: upscaledHeight
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)

        if status == kCVReturnSuccess {
            self.superResolutionPoolAdaptor = pool
            print("  ✅ Created super-resolution pixel buffer pool: \(upscaledWidth)x\(upscaledHeight)")

            // Prime the pool to avoid first-frame delay
            primeSuperResolutionPool(minimumBufferCount: 12)
        } else {
            print("  ⚠️ Failed to create super-resolution pool: \(status)")
        }
    }

    private func primeSuperResolutionPool(minimumBufferCount: Int) {
        guard let pool = superResolutionPoolAdaptor else { return }
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
        print("  🔥 Primed super-resolution pool with \(minimumBufferCount) buffers")
    }

    // Apply super-resolution upscaling to a pixel buffer
    private func applySuperResolution(to sourceBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let transferSession = pixelTransferSession,
              let pool = superResolutionPoolAdaptor else {
            return nil
        }

        // Get destination buffer from pool
        var destinationBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destinationBuffer)

        guard createStatus == kCVReturnSuccess, let destBuffer = destinationBuffer else {
            return nil
        }

        // Perform the upscaling transfer
        let transferStatus = VTPixelTransferSessionTransferImage(transferSession, from: sourceBuffer, to: destBuffer)

        if transferStatus == noErr {
            return destBuffer
        } else {
            return nil
        }
    }

    // Warm up the entire rendering pipeline to eliminate first-frame delay
    private func warmupPipeline() {
        guard let renderer = metalRenderer else {
            DispatchQueue.main.async {
                self.isWarmedUp = false
            }
            return
        }

        print("🔥 Warming up rendering pipeline...")

        // Create a dummy pixel buffer with the expected input dimensions
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        var dummyBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, outputWidth, outputHeight,
                                         kCVPixelFormatType_32BGRA, attributes as CFDictionary, &dummyBuffer)

        guard status == kCVReturnSuccess, let sourceBuffer = dummyBuffer else {
            print("  ⚠️ Failed to create warmup buffer")
            DispatchQueue.main.async {
                self.isWarmedUp = false
            }
            return
        }

        // Fill with black (optional, but helps ensure proper initialization)
        CVPixelBufferLockBaseAddress(sourceBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(sourceBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(sourceBuffer)
            let height = CVPixelBufferGetHeight(sourceBuffer)
            memset(baseAddress, 0, bytesPerRow * height)
        }
        CVPixelBufferUnlockBaseAddress(sourceBuffer, [])

        // Run through Metal LUT renderer (synchronous warmup)
        let semaphore = DispatchSemaphore(value: 0)
        renderer.render(pixelBuffer: sourceBuffer) { [weak self] processedBuffer in
            guard let self = self else {
                semaphore.signal()
                return
            }

            // Also warm up super-resolution (if enabled)
            if self.superResolutionScale > 1.0 {
                if let _ = self.applySuperResolution(to: processedBuffer) {
                    print("  ✅ Metal + Super-Resolution warmed up")
                } else {
                    print("  ✅ Metal pipeline warmed up")
                }
            } else {
                print("  ✅ Metal LUT pipeline warmed up")
            }

            // Warm up video encoder with processed buffer (synchronous)
            self.warmupVideoEncoder(with: processedBuffer, completion: { [weak self] in
                // Signal warmup complete on main thread
                DispatchQueue.main.async {
                    self?.isWarmedUp = true
                    print("🎯 Camera ready - recording enabled")
                }
                semaphore.signal()
            })
        }

        // Wait for warmup to complete (with timeout)
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            print("  ⚠️ Warmup timed out - enabling anyway")
            DispatchQueue.main.async {
                self.isWarmedUp = true
            }
        }
    }

    // Warm up the hardware video encoder to eliminate first-recording delay
    private func warmupVideoEncoder(with pixelBuffer: CVPixelBuffer, completion: @escaping () -> Void) {
        print("  🎬 Warming up video encoder...")

        // Create temporary URL for dummy video
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("warmup_\(UUID().uuidString).mov")

        do {
            // Create asset writer with same settings as actual recording
            let writer = try AVAssetWriter(url: tempURL, fileType: .mov)

            let totalPixels = upscaledWidth * upscaledHeight
            let bitsPerPixel = 0.10
            let calculatedBitrate = Int(Double(totalPixels) * sourceFPS * bitsPerPixel)
            let bitrate = max(15_000_000, min(25_000_000, calculatedBitrate))

            let codec: AVVideoCodecType = .hevc

            // Match real recording settings for accurate warmup
            var compressionSettings: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                kVTCompressionPropertyKey_DataRateLimits as String: [
                    bitrate * 2,
                    1
                ] as [Int],
                AVVideoMaxKeyFrameIntervalKey: Int(sourceFPS * 1),
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: Int(sourceFPS),
                kVTCompressionPropertyKey_RealTime as String: true,
                kVTCompressionPropertyKey_ColorPrimaries as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kVTCompressionPropertyKey_TransferFunction as String: kCVImageBufferTransferFunction_ITU_R_709_2,
                kVTCompressionPropertyKey_YCbCrMatrix as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2
            ]

            compressionSettings[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: upscaledWidth,
                AVVideoHeightKey: upscaledHeight,
                AVVideoCompressionPropertiesKey: compressionSettings
            ]

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true

            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: upscaledWidth,
                kCVPixelBufferHeightKey as String: upscaledHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: pixelBufferAttributes
            )

            writer.add(input)

            guard writer.startWriting() else {
                print("  ⚠️ Failed to start warmup writer")
                try? FileManager.default.removeItem(at: tempURL)
                completion()
                return
            }

            let startTime = CMTime(value: 0, timescale: 600)
            writer.startSession(atSourceTime: startTime)

            // Append one frame to initialize encoder
            if input.isReadyForMoreMediaData {
                adaptor.append(pixelBuffer, withPresentationTime: startTime)
            }

            // Finish immediately
            input.markAsFinished()
            writer.finishWriting {
                // Clean up temporary file
                try? FileManager.default.removeItem(at: tempURL)
                print("  ✅ Video encoder warmed up")
                completion()
            }

        } catch {
            print("  ⚠️ Encoder warmup failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
            completion()
        }
    }

    // MARK: - Permissions

    func checkPermissions() async -> Bool {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        
        var cameraGranted = cameraStatus == .authorized
        
        if cameraStatus == .notDetermined {
            cameraGranted = await AVCaptureDevice.requestAccess(for: .video)
        }
        
        await MainActor.run {
            self.isAuthorized = cameraGranted
        }
        return cameraGranted
    }
    
    // MARK: - Camera Setup
    
    func setupCamera() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    try self.configureSessionLocked()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func configureSessionLocked() throws {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        let device = try selectDevice(position: currentCameraPosition)
        try configureDeviceForHighFrameRate(device)

        // Calculate output dimensions based on camera's native format (3:4 portrait aspect)
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let captureWidth = Int(dims.width)
        let captureHeight = Int(dims.height)

        // For 3:4 portrait output, height should be 4/3 of width
        // Use the smaller dimension as width to maintain quality
        if captureWidth < captureHeight {
            // Camera is in portrait orientation
            outputWidth = captureWidth
            outputHeight = Int(Double(captureWidth) * 4.0 / 3.0)
        } else {
            // Camera is in landscape orientation
            // Use height as our width, scale for 3:4
            outputWidth = captureHeight
            outputHeight = Int(Double(captureHeight) * 4.0 / 3.0)
        }

        print("📐 Camera format: \(captureWidth)x\(captureHeight) → Output: \(outputWidth)x\(outputHeight) (3:4 portrait)")

        // Initialize Metal renderer with calculated dimensions
        initializeMetalRenderer(width: outputWidth, height: outputHeight)

        // Setup super-resolution upscaling (only if enabled)
        if superResolutionScale > 1.0 {
            setupSuperResolution()
        }

        // Start warmup in parallel with camera session setup (don't wait)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.warmupPipeline()
        }

        // Add video input
        let videoInput = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
            self.videoDeviceInput = videoInput
        } else {
            throw CameraError.cannotAddInput
        }

        // Video data output
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            if let connection = videoDataOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .standard
                }
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = (currentCameraPosition == .front)
                }
            }
            print("✅ Using real-time capture output")
        } else {
            throw CameraError.cannotAddOutput
        }

        session.commitConfiguration()

        if !session.isRunning {
            session.startRunning()
        }

        // Preview layer (lowest latency)
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        DispatchQueue.main.async {
            self.previewLayer = preview
        }

        // Note: Pipeline warmup already started in parallel above (after Metal init)
    }
    
    // Helper: choose device for position
    private func selectDevice(position: AVCaptureDevice.Position) throws -> AVCaptureDevice {
        if position == .front {
            if let front = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) {
                return front
            }
            if let frontWide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
                return frontWide
            }
        } else {
            if let ultraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
                return ultraWide
            }
            if let backWide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                return backWide
            }
        }
        throw CameraError.noCameraAvailable
    }
    
    // Helper: configure highest feasible frame rate (prefer highest resolution at max frame rate)
    private func configureDeviceForHighFrameRate(_ device: AVCaptureDevice) throws {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            let desiredFps: Double = 120.0 // target 120 fps
            
            var candidate: (format: AVCaptureDevice.Format, range: AVFrameRateRange)?
            for format in device.formats {
                let ranges = format.videoSupportedFrameRateRanges
                // Find a range that can support at least desiredFps
                guard let supportingRange = ranges.first(where: { $0.maxFrameRate >= desiredFps }) else { continue }
                // Prefer higher resolution among formats that support desiredFps
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let score = Int(dims.width) * Int(dims.height)
                if let current = candidate {
                    let curDims = CMVideoFormatDescriptionGetDimensions(current.format.formatDescription)
                    let curScore = Int(curDims.width) * Int(curDims.height)
                    if score > curScore { candidate = (format, supportingRange) }
                } else {
                    candidate = (format, supportingRange)
                }
            }
            
            // If no format supports 120 fps, fall back to the device's best max-fps format
            if candidate == nil {
                for format in device.formats {
                    let ranges = format.videoSupportedFrameRateRanges
                    guard let maxRange = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { continue }
                    // Prefer formats with higher max fps; for equal fps, prefer higher resolution
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let score = (Int(maxRange.maxFrameRate) * 1_000_000) + (Int(dims.width) * Int(dims.height))
                    if let current = candidate {
                        let curDims = CMVideoFormatDescriptionGetDimensions(current.format.formatDescription)
                        let curScore = (Int(current.range.maxFrameRate) * 1_000_000) + (Int(curDims.width) * Int(curDims.height))
                        if score > curScore { candidate = (format, maxRange) }
                    } else {
                        candidate = (format, maxRange)
                    }
                }
            }
            
            guard let chosen = candidate else {
                print("⚠️ No usable format found; leaving device configuration unchanged")
                return
            }
            let chosenFormat = chosen.format
            let chosenRange = chosen.range
            
            if device.activeFormat != chosenFormat {
                device.activeFormat = chosenFormat
            }
            
            let targetFps = min(chosenRange.maxFrameRate, desiredFps)
            let clampedFps = max(chosenRange.minFrameRate, targetFps)
            let frameDuration = CMTimeMake(value: 1, timescale: Int32(clampedFps.rounded()))
            
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration

            let dims = CMVideoFormatDescriptionGetDimensions(chosenFormat.formatDescription)
            print("✅ Configured \(device.position == .front ? "front" : "back") camera: \(Int(clampedFps)) fps @ \(dims.width)x\(dims.height)")
        } catch {
            throw CameraError.configurationFailed
        }
    }
    
    // MARK: - Toggle Camera
    
    func toggleCamera() {
        guard !isRecording else {
            print("⚠️ Cannot toggle camera while recording")
            return
        }
        let targetPosition: AVCaptureDevice.Position = (currentCameraPosition == .back) ? .front : .back

        // Reset warmup state while switching
        DispatchQueue.main.async {
            self.isWarmedUp = false
        }

        sessionQueue.async {
            self.session.beginConfiguration()
            
            if let currentInput = self.videoDeviceInput {
                self.session.removeInput(currentInput)
                self.videoDeviceInput = nil
            }
            
            do {
                let newDevice = try self.selectDevice(position: targetPosition)
                try self.configureDeviceForHighFrameRate(newDevice)

                // Recalculate output dimensions for new camera (3:4 portrait aspect)
                let dims = CMVideoFormatDescriptionGetDimensions(newDevice.activeFormat.formatDescription)
                let captureWidth = Int(dims.width)
                let captureHeight = Int(dims.height)

                if captureWidth < captureHeight {
                    self.outputWidth = captureWidth
                    self.outputHeight = Int(Double(captureWidth) * 4.0 / 3.0)
                } else {
                    self.outputWidth = captureHeight
                    self.outputHeight = Int(Double(captureHeight) * 4.0 / 3.0)
                }

                print("📐 Switched camera: \(captureWidth)x\(captureHeight) → Output: \(self.outputWidth)x\(self.outputHeight)")

                // Reinitialize Metal renderer with new dimensions
                self.metalRenderer = nil
                self.initializeMetalRenderer(width: self.outputWidth, height: self.outputHeight)

                // Reinitialize super-resolution for new dimensions (only if enabled)
                if self.superResolutionScale > 1.0 {
                    self.pixelTransferSession = nil
                    self.superResolutionPoolAdaptor = nil
                    self.setupSuperResolution()
                }

                // Start warmup in parallel with camera reconfiguration
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.warmupPipeline()
                }

                let newInput = try AVCaptureDeviceInput(device: newDevice)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.videoDeviceInput = newInput
                    DispatchQueue.main.async {
                        self.currentCameraPosition = targetPosition
                    }
                } else {
                    print("❌ Cannot add new camera input")
                }
                
                if let connection = self.videoDataOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .standard
                    }
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = (targetPosition == .front)
                    }
                }
            } catch {
                print("❌ Failed to toggle camera: \(error.localizedDescription)")
            }

            self.session.commitConfiguration()

            // Note: Pipeline warmup already started in parallel above (after Metal init)
        }
    }
    
    // MARK: - Session Control
    
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }
    
    private func ensureSessionRunning() -> Bool {
        var running = false
        sessionQueue.sync {
            if !self.session.isRunning {
                self.session.startRunning()
            }
            running = self.session.isRunning
        }
        return running
    }
    
    // MARK: - Recording Control

    func startRecording() {
        guard !isRecording else { return }

        // Ensure capture session is running before starting recording
        guard ensureSessionRunning() else {
            print("⚠️ Cannot start recording - capture session not running")
            handleRecordingFailure("Recording failed because the camera session is not ready. Please try again.")
            return
        }

        // If not warmed up yet, wait briefly for warmup to complete
        if !isWarmedUp {
            print("⚠️ Recording requested before warmup complete - waiting...")
            // Wait up to 500ms for warmup
            let startTime = Date()
            while !isWarmedUp && Date().timeIntervalSince(startTime) < 0.5 {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if !isWarmedUp {
                print("⚠️ Warmup still incomplete - starting anyway (may have delay)")
            }
        }

        setRecordingState(.preparing)

        // Start recording setup on background queue to not block UI
        DispatchQueue.global(qos: .userInitiated).async {
            self.startRealtimeRecording()
        }
    }
    
    private func stopRecording() {
        guard isRecording else { return }
        stopRealtimeRecording()
    }
    
    // MARK: - Real-Time Recording (LUT applied to saved file only)
    
    func startRealtimeRecording() {
        print("🎬 Starting recording (best quality, native frame rate)...")

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoPath = documentsPath.appendingPathComponent("realtime_\(Date().timeIntervalSince1970).mov")

        do {
            // Ensure we're not already recording
            guard !isRecording else {
                print("⚠️ Already recording, ignoring start request")
                return
            }

            assetWriter = try AVAssetWriter(url: videoPath, fileType: .mov)

            // Optimized compression for performance and quality balance
            // Calculate bitrate based on resolution and frame rate
            // For 1080x1440 @ 120fps: use ~18 Mbps with HEVC for excellent quality
            let totalPixels = upscaledWidth * upscaledHeight
            let bitsPerPixel = 0.10  // Balanced quality/performance with HEVC
            let calculatedBitrate = Int(Double(totalPixels) * sourceFPS * bitsPerPixel)
            let bitrate = max(15_000_000, min(25_000_000, calculatedBitrate))  // 15-25 Mbps range

            // Use HEVC for better quality at same file size (50% more efficient than H.264)
            let codec: AVVideoCodecType
            if #available(iOS 11.0, *) {
                codec = .hevc
            } else {
                codec = .h264
            }

            print("  📊 Recording: \(upscaledWidth)x\(upscaledHeight) @ \(bitrate / 1_000_000) Mbps using \(codec == .hevc ? "HEVC" : "H.264")")
            print("  📱 High-quality compression optimized for sharing")
            print("  🎬 Slow motion: \(Int(sourceFPS))fps → \(Int(targetFPS))fps (\(Int(slowMotionFactor))x slower)")

            // High-quality compression settings with adaptive bitrate
            var compressionSettings: [String: Any] = [
                // Adaptive bitrate - allows bursts for complex scenes
                AVVideoAverageBitRateKey: bitrate,
                kVTCompressionPropertyKey_DataRateLimits as String: [
                    bitrate * 2,  // Max bitrate (2x for complex scenes)
                    1             // Per second
                ] as [Int],

                // Better keyframe strategy - 1s intervals for seeking
                AVVideoMaxKeyFrameIntervalKey: Int(sourceFPS * 1), // keyframe every second

                // Real-time encoding
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: Int(sourceFPS),
                kVTCompressionPropertyKey_RealTime as String: true,

                // Explicit color management (Rec.709)
                kVTCompressionPropertyKey_ColorPrimaries as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kVTCompressionPropertyKey_TransferFunction as String: kCVImageBufferTransferFunction_ITU_R_709_2,
                kVTCompressionPropertyKey_YCbCrMatrix as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2
            ]

            // Codec-specific settings
            if codec == .hevc {
                compressionSettings[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
            } else {
                compressionSettings[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
                compressionSettings[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }

            print("  ⚡ Real-time encoding with adaptive bitrate + Rec.709 color")

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: upscaledWidth,
                AVVideoHeightKey: upscaledHeight,
                AVVideoCompressionPropertiesKey: compressionSettings
            ]

            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            assetWriterInput?.expectsMediaDataInRealTime = true
            assetWriterInput?.transform = .identity

            // Create pixel buffer attributes with pool for better performance
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: upscaledWidth,
                kCVPixelBufferHeightKey as String: upscaledHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]  // Enable IOSurface for zero-copy
            ]

            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: assetWriterInput!,
                sourcePixelBufferAttributes: pixelBufferAttributes
            )
            
            if let input = assetWriterInput, assetWriter!.canAdd(input) {
                assetWriter!.add(input)
            }

            let started = assetWriter!.startWriting()
            if !started {
                let errorDescription = assetWriter?.error?.localizedDescription ?? "Unknown error"
                print("❌ Failed to start writing: \(errorDescription)")
                handleRecordingFailure("Recording failed to start. Please try again.")
                return
            }

            recordingStartTime = nil
            frameCount = 0
            inflightRecordingRenders = 0
            frameRateConversionStartTime = nil
            convertedFrameCount = 0

            // Set recording flag FIRST to enable frame capture
            DispatchQueue.main.async {
                self.recordingProgress = 0.0
                self.isRecording = true  // Set recording flag on main thread
                self.recordingState = .recording
            }

            // Fallback: enforce a hard 1s max duration in case timestamp-based cutoff doesn't trigger
            recordingStopTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: recordingRenderQueue)
            timer.schedule(deadline: .now() + 1.0)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                if self.isRecording {
                    DispatchQueue.main.async { self.stopRecording() }
                }
            }
            recordingStopTimer = timer
            timer.resume()

            print("✅ Writer ready - native resolution with optimized bitrate")
        } catch {
            print("❌ Failed to setup asset writer: \(error.localizedDescription)")
            handleRecordingFailure("Recording setup failed. Please try again.")
        }
    }
    
    func stopRealtimeRecording() {
        // Prevent multiple simultaneous finish operations
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        guard !isFinishingRecording else {
            print("⚠️ Already finishing recording, ignoring duplicate stop request")
            return
        }

        guard isRecording else {
            print("⚠️ Not recording, ignoring stop request")
            return
        }

        print("⏹️ Stopping recording...")
        isFinishingRecording = true

        // Cancel any pending auto-stop timer
        recordingStopTimer?.cancel()
        recordingStopTimer = nil

        // Immediately set recording to false to stop new frames from being processed
        DispatchQueue.main.async {
            self.isRecording = false
        }

        // Mark input as finished before calling finishWriting
        assetWriterInput?.markAsFinished()

        // Check writer status before attempting to finish
        guard let writer = assetWriter, writer.status == .writing else {
            print("⚠️ Writer not in writing state (status: \(assetWriter?.status.rawValue ?? -1)), skipping finish")
            setRecordingState(.idle)
            cleanupRecordingState()
            return
        }

        writer.finishWriting { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if writer.status == .completed {
                    let url = writer.outputURL
                    print("✅ Recording completed: \(url.lastPathComponent)")
                    print("  Frames recorded: \(self.frameCount)")
                    let asset = AVAsset(url: url)
                    let duration = CMTimeGetSeconds(asset.duration)
                    print("  Output duration: \(String(format: "%.3f", duration)) s")
                    if let track = asset.tracks(withMediaType: .video).first {
                        let size = track.naturalSize.applying(track.preferredTransform)
                        print("  Output size (applied transform): \(abs(size.width))x\(abs(size.height))")
                        print("  Preferred transform: \(track.preferredTransform)")
                    }
                    self.processedVideoURL = url
                    self.setRecordingState(.idle)
                    self.cleanupRecordingState()
                } else {
                    let errorDescription = writer.error?.localizedDescription ?? "Unknown error"
                    print("❌ Recording failed: \(errorDescription) (status: \(writer.status.rawValue))")
                    self.handleRecordingFailure("Recording failed to save. Please try again.")
                }
            }
        }
    }

    private func cleanupRecordingState() {
        assetWriter = nil
        assetWriterInput = nil
        pixelBufferAdaptor = nil
        recordingStartTime = nil
        frameCount = 0
        inflightRecordingRenders = 0
        frameRateConversionStartTime = nil
        convertedFrameCount = 0
        recordingProgress = 0.0
        isFinishingRecording = false
    }
    
    private func setRecordingState(_ newState: RecordingState) {
        DispatchQueue.main.async {
            self.recordingState = newState
        }
    }
    
    private func handleRecordingFailure(_ message: String) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingState = .failed(message)
        }
        cleanupRecordingState()
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                      didOutput sampleBuffer: CMSampleBuffer,
                      from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        // RECORDING path: render with LUT into output and write asynchronously
        guard isRecording else {
            return
        }

        guard let renderer = metalRenderer else {
            print("❌ Recording: metalRenderer is nil")
            return
        }

        guard pixelBufferAdaptor != nil else {
            print("❌ Recording: pixelBufferAdaptor is nil")
            return
        }

        // For the first frame, wait a bit for writer to be ready (bounded wait)
        if frameCount == 0 && assetWriterInput?.isReadyForMoreMediaData != true {
            // Wait up to 50ms for writer to become ready on first frame
            let startWait = Date()
            while assetWriterInput?.isReadyForMoreMediaData != true && Date().timeIntervalSince(startWait) < 0.05 {
                Thread.sleep(forTimeInterval: 0.002) // 2ms
            }

            if assetWriterInput?.isReadyForMoreMediaData != true {
                print("❌ Recording: assetWriterInput not ready for data (first frame after wait)")
                return
            }
        } else if assetWriterInput?.isReadyForMoreMediaData != true {
            // Subsequent frames: drop immediately if not ready
            return
        }
        
        if inflightRecordingRenders >= maxInflightRecordingRenders {
            return // drop for recording; preview already updated
        }
        inflightRecordingRenders += 1
        
        let sourceTimestamp = presentationTime

        // Initialize recording session and frame rate conversion tracking
        if self.recordingStartTime == nil {
            self.recordingStartTime = sourceTimestamp
            self.frameRateConversionStartTime = sourceTimestamp
            // Start session with the first frame's timestamp
            self.assetWriter?.startSession(atSourceTime: sourceTimestamp)
            print("🎬 Recording session started at source timestamp \(sourceTimestamp.seconds)")
            print("  📐 Frame rate conversion: \(Int(self.sourceFPS))fps → \(Int(self.targetFPS))fps")
        }

        // Enforce max 1.0s duration based on source timestamps (real-time)
        // This will result in ~4s of slow-motion playback
        if let start = self.recordingStartTime {
            let elapsed = CMTimeSubtract(sourceTimestamp, start)
            let elapsedSeconds = CMTimeGetSeconds(elapsed)

            // Update progress on main thread
            let progress = min(elapsedSeconds / 1.0, 1.0)
            DispatchQueue.main.async {
                self.recordingProgress = progress
            }

            if elapsedSeconds >= 1.0 {
                // Stop and drop further frames
                DispatchQueue.main.async { self.stopRecording() }
                return
            }
        }
        
        // Kick off GPU render; append when GPU completes
        renderer.render(pixelBuffer: pixelBuffer) { [weak self] processedBuffer in
            guard let self = self else { return }
            self.recordingRenderQueue.async {
                // Append on the recording queue after GPU completed
                defer { self.inflightRecordingRenders -= 1 }

                guard self.isRecording,
                      let input = self.assetWriterInput,
                      let adaptor = self.pixelBufferAdaptor else {
                    return
                }

                // Re-check readiness immediately before appending to avoid NSException
                guard input.isReadyForMoreMediaData else {
                    // Drop frame under backpressure
                    return
                }

                // Apply super-resolution upscaling after LUT processing (if enabled)
                let finalBuffer: CVPixelBuffer
                if self.superResolutionScale > 1.0 {
                    // Super-resolution enabled - upscale the frame
                    guard let upscaledBuffer = self.applySuperResolution(to: processedBuffer) else {
                        print("  ⚠️ Super-resolution failed, dropping frame")
                        return
                    }
                    finalBuffer = upscaledBuffer
                } else {
                    // No upscaling - use LUT-processed buffer directly
                    finalBuffer = processedBuffer
                }

                // Calculate slow-motion timestamp by scaling elapsed time
                guard let conversionStart = self.frameRateConversionStartTime else { return }

                // Calculate elapsed time from start
                let elapsed = CMTimeSubtract(sourceTimestamp, conversionStart)

                // Scale the elapsed time by slow-motion factor (4x slower means 4x longer duration)
                let scaledElapsed = CMTimeMultiplyByFloat64(elapsed, multiplier: self.slowMotionFactor)

                // Calculate the final presentation timestamp
                let scaledTimestamp = CMTimeAdd(conversionStart, scaledElapsed)

                if adaptor.append(finalBuffer, withPresentationTime: scaledTimestamp) {
                    self.frameCount += 1
                    self.convertedFrameCount += 1
                    if self.frameCount == 1 {
                        print("  ✅ First frame: real=\(String(format: "%.3f", sourceTimestamp.seconds))s → scaled=\(String(format: "%.3f", scaledTimestamp.seconds))s")
                    } else if self.frameCount % 120 == 0 {
                        print("  📹 Frame \(self.frameCount): real=\(String(format: "%.3f", sourceTimestamp.seconds))s → scaled=\(String(format: "%.3f", scaledTimestamp.seconds))s")
                    }
                } else {
                    print("  ⚠️ Failed to append frame \(self.frameCount + 1)")
                }
            }
        }
    }
}

// MARK: - Camera Errors

enum CameraError: Error, LocalizedError {
    case noCameraAvailable
    case configurationFailed
    case cannotAddInput
    case cannotAddOutput
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .noCameraAvailable:
            return "No camera is available on this device"
        case .configurationFailed:
            return "Failed to configure camera"
        case .cannotAddInput:
            return "Cannot add camera input to session"
        case .cannotAddOutput:
            return "Cannot add output to session"
        case .permissionDenied:
            return "Camera permission denied"
        }
    }
}
