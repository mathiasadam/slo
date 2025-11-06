import AVFoundation
import SwiftUI
import Combine

class CameraManager: NSObject, ObservableObject {
    @Published var isAuthorized = false
    @Published var isRecording = false
    @Published var session = AVCaptureSession()
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    var useRealtimeProcessing = true // Always real-time capture path
    @Published var currentPreviewFrame: CVPixelBuffer? // For UI preview (raw, low-latency)
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
    private let recordingRenderQueue = DispatchQueue(label: "com.slo.recording.render", qos: .userInitiated)
    
    // Timing / counters
    private var recordingStartTime: CMTime?
    private var frameCount = 0
    private var inflightRecordingRenders = 0
    private let maxInflightRecordingRenders = 4 // increased to absorb spikes
    
    // Preview throttling for UI smoothness (60fps)
    private var lastPreviewFrameTime: CMTime = .zero
    private let previewFrameInterval = CMTime(value: 1, timescale: 60)
    
    // Progress / UI
    @Published var recordingProgress: Double = 0.0
    @Published var processedVideoURL: URL?
    @Published var isProcessing = false
    private var recordingTimer: Timer?
    private let recordingDuration: Double = 1.5 // capture 1.5s at 240fps (≈360 frames)
    
    // Forced 3:4 output size for saved video
    private let outputWidth = 1080
    private let outputHeight = 1440 // 3:4 portrait
    
    // Target output cadence for smoother slow motion
    private let targetOutputFPS: Int32 = 240 // reduced to sustainable cadence
    private let slowDownMultiplier: Int32 = 3 // 3x slower (1.5s -> 4.5s)
    
    override init() {
        super.init()
        do {
            self.metalRenderer = try MetalLUTRenderer(targetWidth: outputWidth, targetHeight: outputHeight)
            self.metalRenderer?.setDensityGamma(1.06)
            print("✅ Metal renderer initialized - real-time processing available (3:4 target)")
        } catch {
            print("⚠️ Metal renderer failed to initialize: \(error.localizedDescription)")
            self.useRealtimeProcessing = false
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
    
    func setupCamera() throws {
        session.beginConfiguration()
        session.sessionPreset = .high
        
        let device = try selectDevice(position: currentCameraPosition)
        try configureDeviceForHighFrameRate(device)
        
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
                    // Step 2 will change this to .off if needed, leaving as-is for now
                    connection.preferredVideoStabilizationMode = .cinematic
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
        
        // Preview layer (lowest latency)
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        self.previewLayer = preview
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
    
    // Helper: configure highest feasible frame rate (prefer 240 fps back, 120 fps front; else highest supported)
    private func configureDeviceForHighFrameRate(_ device: AVCaptureDevice) throws {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            let desiredFps: Double = (device.position == .back) ? 240.0 : 120.0
            
            var bestFormat: AVCaptureDevice.Format?
            var bestRange: AVFrameRateRange?
            
            for format in device.formats {
                let ranges = format.videoSupportedFrameRateRanges
                guard !ranges.isEmpty else { continue }
                
                guard let maxRange = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { continue }
                
                if maxRange.maxFrameRate >= desiredFps {
                    if let currentBest = bestFormat {
                        let curDims = CMVideoFormatDescriptionGetDimensions(currentBest.formatDescription)
                        let newDims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        let curPixels = Int(curDims.width) * Int(curDims.height)
                        let newPixels = Int(newDims.width) * Int(newDims.height)
                        if newPixels <= curPixels { continue }
                    }
                    bestFormat = format
                    bestRange = maxRange
                } else {
                    if bestRange == nil || maxRange.maxFrameRate > bestRange!.maxFrameRate {
                        bestFormat = format
                        bestRange = maxRange
                    }
                }
            }
            
            guard let chosenFormat = bestFormat, let chosenRange = bestRange else {
                print("⚠️ No usable format found; leaving device configuration unchanged")
                return
            }
            
            if device.activeFormat != chosenFormat {
                device.activeFormat = chosenFormat
            }
            
            let targetFps = min(chosenRange.maxFrameRate, desiredFps)
            let clampedFps = max(chosenRange.minFrameRate, min(targetFps, chosenRange.maxFrameRate))
            let timescale = CMTimeScale(clampedFps.rounded())
            let frameDuration = CMTime(value: 1, timescale: timescale)
            
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            
            let dims = CMVideoFormatDescriptionGetDimensions(chosenFormat.formatDescription)
            print("✅ Configured \(device.position == .front ? "front" : "back") camera: ~\(Int(clampedFps)) fps @ \(dims.width)x\(dims.height)")
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
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.beginConfiguration()
            
            if let currentInput = self.videoDeviceInput {
                self.session.removeInput(currentInput)
                self.videoDeviceInput = nil
            }
            
            do {
                let newDevice = try self.selectDevice(position: targetPosition)
                try self.configureDeviceForHighFrameRate(newDevice)
                
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
                        connection.preferredVideoStabilizationMode = .cinematic
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
        }
    }
    
    // MARK: - Session Control
    
    func startSession() {
        DispatchQueue(label: "camera.session").async { [weak self] in
            self?.session.startRunning()
        }
    }
    
    func stopSession() {
        DispatchQueue(label: "camera.session").async { [weak self] in
            self?.session.stopRunning()
        }
    }
    
    // MARK: - Recording Control
    
    func startRecording() {
        guard !isRecording else { return }
        startRealtimeRecording()
    }
    
    private func stopRecording() {
        guard isRecording else { return }
        stopRealtimeRecording()
    }
    
    private func startProgressTimer() {
        let startTime = Date()
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(elapsed / self.recordingDuration, 1.0)
            self.recordingProgress = progress
            if progress >= 1.0 {
                timer.invalidate()
                self.stopRecording()
            }
        }
    }
    
    // MARK: - Real-Time Recording (LUT applied to saved file only)
    
    func startRealtimeRecording() {
        print("🎬 Starting real-time recording (3:4 output, preview real-time)...")
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoPath = documentsPath.appendingPathComponent("realtime_\(Date().timeIntervalSince1970).mov")
        
        do {
            assetWriter = try AVAssetWriter(url: videoPath, fileType: .mov)
            
            // Force 3:4 output size
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outputWidth,
                AVVideoHeightKey: outputHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 20_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            
            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            assetWriterInput?.expectsMediaDataInRealTime = true
            assetWriterInput?.transform = .identity
            
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: assetWriterInput!,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: outputWidth,
                    kCVPixelBufferHeightKey as String: outputHeight
                ]
            )
            
            if let input = assetWriterInput, assetWriter!.canAdd(input) {
                assetWriter!.add(input)
            }
            
            let started = assetWriter!.startWriting()
            if !started {
                print("❌ Failed to start writing: \(assetWriter?.error?.localizedDescription ?? "Unknown error")")
            }
            
            recordingStartTime = nil
            frameCount = 0
            inflightRecordingRenders = 0
            
            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingProgress = 0.0
            }
            
            startProgressTimer()
            print("✅ Writer ready at \(outputWidth)x\(outputHeight) (3:4), 20 Mbps, target output \(targetOutputFPS) fps, slowdown x\(slowDownMultiplier)")
        } catch {
            print("❌ Failed to setup asset writer: \(error.localizedDescription)")
        }
    }
    
    func stopRealtimeRecording() {
        print("⏹️ Stopping real-time recording...")
        
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        DispatchQueue.main.async {
            self.isRecording = false
            self.isProcessing = true
        }
        
        assetWriterInput?.markAsFinished()
        
        assetWriter?.finishWriting { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isProcessing = false
                if let url = self.assetWriter?.outputURL,
                   self.assetWriter?.status == .completed {
                    print("✅ Real-time recording completed: \(url.lastPathComponent)")
                    print("  Frames recorded: \(self.frameCount)")
                    let asset = AVAsset(url: url)
                    let duration = CMTimeGetSeconds(asset.duration)
                    print("  Output duration: \(String(format: "%.3f", duration)) s (expected ~\(self.recordingDuration * Double(self.slowDownMultiplier)))")
                    if let track = asset.tracks(withMediaType: .video).first {
                        let size = track.naturalSize.applying(track.preferredTransform)
                        print("  Output size (applied transform): \(abs(size.width))x\(abs(size.height))")
                        print("  Preferred transform: \(track.preferredTransform)")
                    }
                    self.processedVideoURL = url
                } else {
                    print("❌ Recording failed: \(self.assetWriter?.error?.localizedDescription ?? "Unknown error")")
                }
                
                self.assetWriter = nil
                self.assetWriterInput = nil
                self.pixelBufferAdaptor = nil
                self.recordingStartTime = nil
                self.frameCount = 0
                self.inflightRecordingRenders = 0
                self.lastPreviewFrameTime = .zero
            }
        }
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
        
        // 1) Low-latency PREVIEW: update UI from raw buffer at up to 60fps
        let timeSinceLastPreview = CMTimeSubtract(presentationTime, lastPreviewFrameTime)
        if CMTimeCompare(timeSinceLastPreview, previewFrameInterval) >= 0 {
            lastPreviewFrameTime = presentationTime
            let previewBuffer = pixelBuffer
            DispatchQueue.main.async { [weak self] in
                self?.currentPreviewFrame = previewBuffer
            }
        }
        
        // 2) RECORDING path: render with LUT into 3:4 and write asynchronously
        guard isRecording,
              let renderer = metalRenderer,
              let adaptor = pixelBufferAdaptor,
              assetWriterInput?.isReadyForMoreMediaData == true
        else {
            return
        }
        
        if inflightRecordingRenders >= maxInflightRecordingRenders {
            return // drop for recording; preview already updated
        }
        inflightRecordingRenders += 1
        
        let sourceTimestamp = presentationTime
        
        // Compute adjusted PTS now (before async)
        let adjustedPTS: CMTime = {
            if self.recordingStartTime == nil {
                self.recordingStartTime = sourceTimestamp
                self.assetWriter?.startSession(atSourceTime: .zero)
                print("🎬 Recording session started at .zero (first source ts: \(sourceTimestamp.seconds))")
            }
            let startTs = self.recordingStartTime ?? sourceTimestamp
            let elapsedTime = CMTimeSubtract(sourceTimestamp, startTs)
            var adjustedTime = CMTimeMultiplyByRatio(elapsedTime, multiplier: self.slowDownMultiplier, divisor: 1)
            let frameDuration = CMTime(value: 1, timescale: self.targetOutputFPS)
            let frames = llround(CMTimeGetSeconds(adjustedTime) / CMTimeGetSeconds(frameDuration))
            adjustedTime = CMTimeMultiply(frameDuration, multiplier: Int32(frames))
            return adjustedTime
        }()
        
        // Kick off GPU render; append when GPU completes
        renderer.render(pixelBuffer: pixelBuffer) { [weak self] processedBuffer in
            guard let self = self else { return }
            self.recordingRenderQueue.async {
                // Append on the recording queue after GPU completed
                if adaptor.append(processedBuffer, withPresentationTime: adjustedPTS) {
                    self.frameCount += 1
                    if self.frameCount == 1 {
                        print("  ✅ First frame recorded at \(adjustedPTS.seconds)s")
                    } else if self.frameCount % 240 == 0 {
                        print("  📹 Recorded \(self.frameCount) frames... last ts \(adjustedPTS.seconds)s")
                    }
                } else {
                    print("  ⚠️ Failed to append frame \(self.frameCount + 1)")
                }
                self.inflightRecordingRenders -= 1
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
            return "Camera or microphone permission denied"
        }
    }
}
