import AVFoundation
import SwiftUI

class CameraManager: NSObject, ObservableObject {
    @Published var isAuthorized = false
    @Published var session = AVCaptureSession()
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    
    private var videoOutput = AVCaptureMovieFileOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    
    override init() {
        super.init()
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
        
        // Add movie file output
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
        } else {
            throw CameraError.cannotAddOutput
        }
        
        session.commitConfiguration()
        
        // Create preview layer
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        
        await MainActor.run {
            self.previewLayer = preview
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

