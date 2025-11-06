import AVFoundation
import SwiftUI
import Combine

class CameraManager: NSObject, ObservableObject {
    @Published var isAuthorized = false
    @Published var isRecording = false
    @Published var session = AVCaptureSession()
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    // COMMENTED OUT: Post-Process mode disabled - always use Real-Time
    // @Published var useRealtimeProcessing = true {
    //     didSet {
    //         if oldValue != useRealtimeProcessing {
    //             // Restart session to switch modes
    //             restartSessionForModeChange()
    //         }
    //     }
    // }
    let useRealtimeProcessing = true // Always use Real-Time mode
    @Published var currentPreviewFrame: CVPixelBuffer? // For Metal preview
    
    // COMMENTED OUT: Post-Process mode output (disabled)
    // private var videoOutput = AVCaptureMovieFileOutput()
    private var videoDataOutput = AVCaptureVideoDataOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    
    // Real-time processing
    private var metalRenderer: MetalLUTRenderer?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let videoProcessingQueue = DispatchQueue(label: "com.slo.videoprocessing", qos: .userInteractive)
    private var recordingStartTime: CMTime?
    private var frameCount = 0
    
    // Frame throttling for preview (process fewer frames for display)
    private var lastPreviewFrameTime: CMTime = .zero
    private let previewFrameInterval = CMTime(value: 1, timescale: 60) // 60fps max for preview
    private var isProcessingFrame = false // Prevent frame buildup
    
    override init() {
        super.init()
        
        // Try to initialize Metal renderer
        do {
            self.metalRenderer = try MetalLUTRenderer()
            print("✅ Metal renderer initialized - real-time processing available")
        } catch {
            print("⚠️ Metal renderer failed to initialize: \(error.localizedDescription)")
            print("  Falling back to post-processing mode")
            self.useRealtimeProcessing = false
        }
    }
    
    // MARK: - Permissions
    
    func checkPermissions() async -> Bool {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        
        var cameraGranted = cameraStatus == .authorized
        var microphoneGranted = microphoneStatus == .authorized
        
        // Request camera permission if needed
        if cameraStatus == .notDetermined {
            cameraGranted = await AVCaptureDevice.requestAccess(for: .video)
        }
        
        // Request microphone permission if needed
        if microphoneStatus == .notDetermined {
            microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        }
        
        let bothGranted = cameraGranted && microphoneGranted
        
        await MainActor.run {
            self.isAuthorized = bothGranted
        }
        
        return bothGranted
    }
    
    // MARK: - Camera Setup
    
    func setupCamera() throws {
        // Configure session for high quality
        session.beginConfiguration()
        session.sessionPreset = .high
        
        // Get ultra-wide camera if available, else wide-angle
        var videoDevice: AVCaptureDevice?
        if let ultraWideCamera = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            videoDevice = ultraWideCamera
        } else {
            videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
        
        guard let videoDevice = videoDevice else {
            throw CameraError.noCameraAvailable
        }
        
        // Configure for 240fps slow motion
        do {
            try videoDevice.lockForConfiguration()
            
            // Find 240fps format
            var targetFormat: AVCaptureDevice.Format?
            var targetFrameRateRange: AVFrameRateRange?
            
            for format in videoDevice.formats {
                for range in format.videoSupportedFrameRateRanges {
                    if range.maxFrameRate == 240 {
                        targetFormat = format
                        targetFrameRateRange = range
                        break
                    }
                }
                if targetFormat != nil {
                    break
                }
            }
            
            // Set format if 240fps is available
            if let format = targetFormat, let frameRateRange = targetFrameRateRange {
                videoDevice.activeFormat = format
                videoDevice.activeVideoMinFrameDuration = frameRateRange.minFrameDuration
                videoDevice.activeVideoMaxFrameDuration = frameRateRange.minFrameDuration
            } else {
                // Fallback to highest available frame rate
                if let format = videoDevice.formats.first,
                   let range = format.videoSupportedFrameRateRanges.first {
                    videoDevice.activeVideoMinFrameDuration = range.minFrameDuration
                    videoDevice.activeVideoMaxFrameDuration = range.minFrameDuration
                }
            }
            
            videoDevice.unlockForConfiguration()
        } catch {
            throw CameraError.configurationFailed
        }
        
        // Add video input
        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        
        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
            self.videoDeviceInput = videoInput
        } else {
            throw CameraError.cannotAddInput
        }
        
        // Add audio input
        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
                self.audioDeviceInput = audioInput
            }
        }
        
        // Add video data output for real-time processing (Real-Time mode only)
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: videoProcessingQueue)
        
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            
            // Configure connection for portrait orientation
            if let connection = videoDataOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .cinematic
                }
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
            print("✅ Using real-time Metal processing mode")
        } else {
            throw CameraError.cannotAddOutput
        }
        
        // COMMENTED OUT: Post-Process mode output (disabled)
        /*
        if useRealtimeProcessing {
            // Configure video data output for real-time processing
            videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.setSampleBufferDelegate(self, queue: videoProcessingQueue)
            
            if session.canAddOutput(videoDataOutput) {
                session.addOutput(videoDataOutput)
                
                // Configure connection for portrait orientation
                if let connection = videoDataOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .cinematic
                    }
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }
                }
                print("✅ Using real-time Metal processing mode")
            } else {
                throw CameraError.cannotAddOutput
            }
        } else {
            // Fallback to movie file output for post-processing
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
                
                // Configure video output connection for portrait orientation
                if let connection = videoOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .cinematic
                    }
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }
                }
                print("✅ Using post-processing mode")
            } else {
                throw CameraError.cannotAddOutput
            }
        }
        */
        
        session.commitConfiguration()
        
        // Create preview layer
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        self.previewLayer = preview
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
    
    // COMMENTED OUT: Mode switching disabled (Post-Process mode removed)
    /*
    private func restartSessionForModeChange() {
        guard !isRecording else { return }
        
        print("🔄 Restarting session for mode change...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Stop current session
            self.session.stopRunning()
            
            // Reconfigure session
            self.session.beginConfiguration()
            
            // Remove existing outputs
            for output in self.session.outputs {
                self.session.removeOutput(output)
            }
            
            // Add appropriate output based on new mode
            if self.useRealtimeProcessing {
                // Configure video data output for real-time processing
                self.videoDataOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoProcessingQueue)
                
                if self.session.canAddOutput(self.videoDataOutput) {
                    self.session.addOutput(self.videoDataOutput)
                    
                    if let connection = self.videoDataOutput.connection(with: .video) {
                        if connection.isVideoStabilizationSupported {
                            connection.preferredVideoStabilizationMode = .cinematic
                        }
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = .portrait
                        }
                    }
                    print("✅ Switched to real-time Metal processing mode")
                }
            } else {
                // Configure movie file output for post-processing
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                    
                    if let connection = self.videoOutput.connection(with: .video) {
                        if connection.isVideoStabilizationSupported {
                            connection.preferredVideoStabilizationMode = .cinematic
                        }
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = .portrait
                        }
                    }
                    print("✅ Switched to post-processing mode")
                }
            }
            
            self.session.commitConfiguration()
            
            // Restart session
            self.session.startRunning()
        }
    }
    */
    
    // MARK: - Recording
    
    @Published var recordingProgress: Double = 0.0
    @Published var processedVideoURL: URL?
    @Published var isProcessing = false
    private var recordingTimer: Timer?
    private let recordingDuration: Double = 1.5
    
    func startRecording() {
        guard !isRecording else { return }
        
        // Real-Time mode only
        startRealtimeRecording()
        
        // COMMENTED OUT: Post-Process mode (disabled)
        /*
        if useRealtimeProcessing {
            // Use real-time Metal processing
            startRealtimeRecording()
        } else {
            // Fallback to traditional recording with post-processing
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let videoPath = documentsPath.appendingPathComponent("video_\(Date().timeIntervalSince1970).mov")
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.videoOutput.startRecording(to: videoPath, recordingDelegate: self)
                self.isRecording = true
                self.recordingProgress = 0.0
                
                // Start progress timer
                self.startProgressTimer()
            }
        }
        */
    }
    
    private func startProgressTimer() {
        let startTime = Date()
        recordingTimer?.invalidate()
        
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(elapsed / self.recordingDuration, 1.0)
            
            self.recordingProgress = progress
            
            if progress >= 1.0 {
                timer.invalidate()
                self.stopRecording()
            }
        }
    }
    
    private func stopRecording() {
        guard isRecording else { return }
        
        // Real-Time mode only
        stopRealtimeRecording()
        
        // COMMENTED OUT: Post-Process mode (disabled)
        /*
        if useRealtimeProcessing {
            // Stop real-time recording
            stopRealtimeRecording()
        } else {
            // Stop traditional recording
            recordingTimer?.invalidate()
            recordingTimer = nil
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.videoOutput.stopRecording()
                self.isRecording = false
                self.recordingProgress = 0.0
            }
        }
        */
    }
    
    // MARK: - COMMENTED OUT: Post-Process Slow Motion (disabled)
    
    // @Published var lutProcessingProgress: Double = 0.0
    // private var currentLUTProcessor: LUTProcessor?
    
    /*
    func createSlowMotionVideo(from sourceURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVAsset(url: sourceURL)
        let composition = AVMutableComposition()
        
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ),
        let assetVideoTrack = asset.tracks(withMediaType: .video).first
        else {
            completion(.failure(CameraError.configurationFailed))
            return
        }
        
        // Insert original footage
        let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        try? videoTrack.insertTimeRange(timeRange, of: assetVideoTrack, at: .zero)
        
        // Preserve the original video orientation/transform
        videoTrack.preferredTransform = assetVideoTrack.preferredTransform
        
        // Scale from 1.5s to 3s (2x time stretch = 2x slow motion at 120fps)
        let targetDuration = CMTime(seconds: 3.0, preferredTimescale: 600)
        videoTrack.scaleTimeRange(timeRange, toDuration: targetDuration)
        
        // No audio - video only
        
        // Export processed video (without LUT first)
        let tempOutputURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("temp_slowmo_\(Date().timeIntervalSince1970).mov")
        
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            completion(.failure(CameraError.configurationFailed))
            return
        }
        
        exportSession.outputURL = tempOutputURL
        exportSession.outputFileType = .mov
        exportSession.exportAsynchronously { [weak self] in
            guard let self = self else { return }
            
            if exportSession.status == .completed {
                // Now apply LUT to the slow-motion video
                self.applyLUT(to: tempOutputURL, completion: completion)
            } else {
                completion(.failure(exportSession.error ?? CameraError.configurationFailed))
            }
        }
    }
    
    private func applyLUT(to sourceURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        // Get LUT file path - try multiple methods
        var lutURL: URL?
        
        // Method 1: Try with subdirectory
        lutURL = Bundle.main.url(forResource: "Fuji_Neopan", withExtension: "cube", subdirectory: "Utilities")
        
        // Method 2: Try without subdirectory
        if lutURL == nil {
            lutURL = Bundle.main.url(forResource: "Fuji_Neopan", withExtension: "cube")
        }
        
        // Method 3: Try direct path in bundle
        if lutURL == nil {
            if let bundlePath = Bundle.main.path(forResource: "Fuji_Neopan", ofType: "cube") {
                lutURL = URL(fileURLWithPath: bundlePath)
            }
        }
        
        guard let finalLutURL = lutURL else {
            // If LUT is not found, return the source video without LUT
            print("❌ ERROR: LUT file not found in bundle. Tried:")
            print("  - Bundle.main.url(forResource: 'Fuji_Neopan', withExtension: 'cube', subdirectory: 'Utilities')")
            print("  - Bundle.main.url(forResource: 'Fuji_Neopan', withExtension: 'cube')")
            print("  - Bundle.main.path(forResource: 'Fuji_Neopan', ofType: 'cube')")
            print("  - Video will be processed without LUT")
            completion(.success(sourceURL))
            return
        }
        
        print("✅ Found LUT file at: \(finalLutURL.path)")
        
        // Create output URL
        let finalOutputURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("final_\(Date().timeIntervalSince1970).mov")
        
        do {
            // Keep a strong reference to the processor until completion
            let lutProcessor = try LUTProcessor(cubeFileURL: finalLutURL)
            self.currentLUTProcessor = lutProcessor
            
            lutProcessor.applyLUT(
                to: sourceURL,
                outputURL: finalOutputURL,
                progress: { [weak self] progress in
                    DispatchQueue.main.async {
                        self?.lutProcessingProgress = progress
                    }
                },
                completion: { [weak self] result in
                    // Clean up temporary file
                    try? FileManager.default.removeItem(at: sourceURL)
                    
                    DispatchQueue.main.async {
                        self?.lutProcessingProgress = 0.0
                        self?.currentLUTProcessor = nil // Release the processor
                    }
                    
                    completion(result)
                }
            )
        } catch {
            // If LUT processing fails, return the source video
            print("Warning: LUT processing failed: \(error.localizedDescription)")
            currentLUTProcessor = nil
            completion(.success(sourceURL))
        }
    }
    */
    // END COMMENTED OUT: Post-Process functions
    
    // MARK: - Real-Time Recording Methods
    
    func startRealtimeRecording() {
        guard !isRecording else { return } // Always real-time mode
        
        print("🎬 Starting real-time recording...")
        
        // Generate file URL
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoPath = documentsPath.appendingPathComponent("realtime_\(Date().timeIntervalSince1970).mov")
        
        // Setup AVAssetWriter
        do {
            assetWriter = try AVAssetWriter(url: videoPath, fileType: .mov)
            
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1920,
                AVVideoHeightKey: 1080,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 10_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            
            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            assetWriterInput?.expectsMediaDataInRealTime = true
            
            // Set transform for portrait
            assetWriterInput?.transform = CGAffineTransform(rotationAngle: .pi / 2)
            
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: assetWriterInput!,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 1920,
                    kCVPixelBufferHeightKey as String: 1080
                ]
            )
            
            if let input = assetWriterInput, assetWriter!.canAdd(input) {
                assetWriter!.add(input)
            }
            
            assetWriter!.startWriting()
            recordingStartTime = nil
            frameCount = 0
            
            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingProgress = 0.0
            }
            
            // Start timer to auto-stop after 1.5 seconds
            startProgressTimer()
            
            print("✅ Asset writer ready, recording will start with first frame")
            
        } catch {
            print("❌ Failed to setup asset writer: \(error.localizedDescription)")
        }
    }
    
    func stopRealtimeRecording() {
        guard isRecording else { return }
        
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
                    self.processedVideoURL = url
                } else {
                    print("❌ Recording failed: \(self.assetWriter?.error?.localizedDescription ?? "Unknown error")")
                }
                
                // Cleanup
                self.assetWriter = nil
                self.assetWriterInput = nil
                self.pixelBufferAdaptor = nil
                self.recordingStartTime = nil
                self.frameCount = 0
                self.isProcessingFrame = false
                self.lastPreviewFrameTime = .zero
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                      didOutput sampleBuffer: CMSampleBuffer,
                      from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        // Skip frame if still processing previous frame (prevents buildup)
        guard !isProcessingFrame else {
            return
        }
        
        // Throttle preview updates to 60fps max (but record all frames when recording)
        let shouldUpdatePreview: Bool
        if isRecording {
            // Always process when recording
            shouldUpdatePreview = true
        } else {
            // Throttle preview to 60fps
            let timeSinceLastPreview = CMTimeSubtract(presentationTime, lastPreviewFrameTime)
            shouldUpdatePreview = CMTimeCompare(timeSinceLastPreview, previewFrameInterval) >= 0
        }
        
        guard shouldUpdatePreview else {
            return
        }
        
        isProcessingFrame = true
        lastPreviewFrameTime = presentationTime
        
        // Process frame with Metal LUT
        if let renderer = metalRenderer, let processedBuffer = renderer.render(pixelBuffer: pixelBuffer) {
            // Update preview on main thread (only if not recording, to reduce overhead)
            if !isRecording {
                DispatchQueue.main.async { [weak self] in
                    self?.currentPreviewFrame = processedBuffer
                }
            }
            
            // Write to video if recording
            if isRecording, let adaptor = pixelBufferAdaptor, assetWriterInput?.isReadyForMoreMediaData == true {
                autoreleasepool {
                    if recordingStartTime == nil {
                        recordingStartTime = presentationTime
                        assetWriter?.startSession(atSourceTime: presentationTime)
                        print("🎬 Recording session started at time: \(presentationTime.seconds)")
                    }
                    
                    // Calculate adjusted time for 2x slow motion
                    let elapsedTime = CMTimeSubtract(presentationTime, recordingStartTime!)
                    let adjustedTime = CMTimeMultiply(elapsedTime, multiplier: 2) // 2x slower
                    
                    // Append frame with adjusted timestamp
                    if adaptor.append(processedBuffer, withPresentationTime: adjustedTime) {
                        frameCount += 1
                        
                        if frameCount == 1 {
                            print("  ✅ First frame recorded")
                        } else if frameCount % 60 == 0 {
                            print("  📹 Recorded \(frameCount) frames...")
                        }
                    } else {
                        print("  ⚠️ Failed to append frame \(frameCount + 1)")
                    }
                    
                    // Update preview periodically during recording
                    if frameCount % 4 == 0 { // Update every 4th frame during recording
                        DispatchQueue.main.async { [weak self] in
                            self?.currentPreviewFrame = processedBuffer
                        }
                    }
                }
            }
            
            isProcessingFrame = false
        } else {
            // No Metal processing - update preview with original buffer
            if !isRecording {
                DispatchQueue.main.async { [weak self] in
                    self?.currentPreviewFrame = pixelBuffer
                }
            }
            isProcessingFrame = false
        }
    }
}

// COMMENTED OUT: AVCaptureFileOutputRecordingDelegate (Post-Process mode only)
/*
// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        print("Recording started")
    }
    
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
        }
        
        if let error = error {
            print("Recording error: \(error.localizedDescription)")
        } else {
            // Process video for slow motion
            DispatchQueue.main.async { [weak self] in
                self?.isProcessing = true
            }
            
            createSlowMotionVideo(from: outputFileURL) { [weak self] result in
                DispatchQueue.main.async {
                    self?.isProcessing = false
                    
                    switch result {
                    case .success(let url):
                        self?.processedVideoURL = url
                    case .failure(let error):
                        print("Processing error: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
*/

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

