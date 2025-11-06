import SwiftUI
import AVFoundation

struct CameraView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var permissionError: String?
    @State private var setupError: String?
    @State private var showingPreview = false
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            if cameraManager.isAuthorized {
                // Metal preview with LUT applied in real-time (Real-Time mode only)
                MetalPreviewView(pixelBuffer: cameraManager.currentPreviewFrame)
                    .ignoresSafeArea()
                    .onAppear {
                        cameraManager.startSession()
                    }
                    .onDisappear {
                        cameraManager.stopSession()
                    }
                
                // COMMENTED OUT: Traditional preview (Post-Process mode disabled)
                /*
                if cameraManager.useRealtimeProcessing {
                    // Metal preview with LUT applied in real-time
                    MetalPreviewView(pixelBuffer: cameraManager.currentPreviewFrame)
                        .ignoresSafeArea()
                        .onAppear {
                            cameraManager.startSession()
                        }
                        .onDisappear {
                            cameraManager.stopSession()
                        }
                } else if let previewLayer = cameraManager.previewLayer {
                    // Traditional preview without LUT
                    CameraPreviewView(previewLayer: previewLayer)
                        .ignoresSafeArea()
                        .onAppear {
                            cameraManager.startSession()
                        }
                        .onDisappear {
                            cameraManager.stopSession()
                        }
                }
                */
            } else if let error = permissionError ?? setupError {
                VStack(spacing: 20) {
                    Text("Camera Access Required")
                        .foregroundColor(.white)
                        .font(.title2)
                    
                    Text(error)
                        .foregroundColor(.white)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else {
                ProgressView()
                    .tint(.white)
            }
            
            // Recording indicator (Real-Time mode only)
            VStack {
                HStack {
                    // COMMENTED OUT: Mode toggle button (Post-Process mode disabled)
                    /*
                    Button(action: {
                        cameraManager.useRealtimeProcessing.toggle()
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: cameraManager.useRealtimeProcessing ? "sparkles" : "hourglass")
                                .font(.system(size: 20))
                            Text(cameraManager.useRealtimeProcessing ? "Real-Time" : "Post-Process")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)
                    }
                    .padding(.top, 24)
                    .padding(.leading, 24)
                    .disabled(cameraManager.isRecording)
                    */
                    
                    Spacer()
                    
                    // Recording indicator (top-right)
                    if cameraManager.isRecording {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 12, height: 12)
                            .scaleEffect(pulseScale)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                                    pulseScale = 1.3
                                }
                            }
                            .padding(.top, 24)
                            .padding(.trailing, 24)
                    }
                }
                Spacer()
            }
            
            // Record button / Progress indicator
            VStack {
                Spacer()
                
                if cameraManager.isRecording {
                    // Progress indicator during recording
                    ZStack {
                        // Background circle
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 6)
                            .frame(width: 80, height: 80)
                        
                        // Progress circle
                        Circle()
                            .trim(from: 0, to: cameraManager.recordingProgress)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .frame(width: 80, height: 80)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.016), value: cameraManager.recordingProgress)
                        
                        // Timer text in center
                        Text(String(format: "%.1f", (1.0 - cameraManager.recordingProgress) * 1.5))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.bottom, 40)
                } else {
                    // Record button
                    Button(action: recordButtonTapped) {
                        ZStack {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 80, height: 80)
                            
                            Circle()
                                .fill(Color.red)
                                .frame(width: 64, height: 64)
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        // COMMENTED OUT: Processing overlay (Post-Process mode disabled)
        /*
        .overlay {
            if cameraManager.isProcessing && !cameraManager.useRealtimeProcessing {
                ZStack {
                    Color.black.opacity(0.7)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        // Show circular progress if we have LUT progress
                        if cameraManager.lutProcessingProgress > 0 {
                            ZStack {
                                Circle()
                                    .stroke(Color.white.opacity(0.3), lineWidth: 8)
                                    .frame(width: 100, height: 100)
                                
                                Circle()
                                    .trim(from: 0, to: cameraManager.lutProcessingProgress)
                                    .stroke(Color.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                    .frame(width: 100, height: 100)
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 0.1), value: cameraManager.lutProcessingProgress)
                                
                                Text("\(Int(cameraManager.lutProcessingProgress * 100))%")
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                            }
                        } else {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                        }
                        
                        Text(cameraManager.lutProcessingProgress > 0 ? "Applying Fuji Neopan LUT..." : "Processing...")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
            }
        }
        */
        .fullScreenCover(isPresented: $showingPreview) {
            if let videoURL = cameraManager.processedVideoURL {
                PreviewView(
                    videoURL: videoURL,
                    onRetake: {
                        showingPreview = false
                        cameraManager.processedVideoURL = nil
                    },
                    onSend: {
                        showingPreview = false
                        cameraManager.processedVideoURL = nil
                        // Handle send action here
                    }
                )
            }
        }
        .onChange(of: cameraManager.processedVideoURL) { newValue in
            if newValue != nil {
                showingPreview = true
            }
        }
        .task {
            await setupCamera()
        }
    }
    
    // Animation state for pulsing indicator
    @State private var pulseScale: CGFloat = 1.0
    
    private func setupCamera() async {
        // Check permissions first
        let permissionsGranted = await cameraManager.checkPermissions()
        
        if !permissionsGranted {
            permissionError = "Camera and microphone access are required. Please enable them in Settings."
            return
        }
        
        // Setup camera
        do {
            try cameraManager.setupCamera()
        } catch let error as CameraError {
            setupError = error.localizedDescription
        } catch {
            setupError = "An unexpected error occurred while setting up the camera."
        }
    }
    
    private func recordButtonTapped() {
        // Only allow starting recording, not stopping
        guard !cameraManager.isRecording else { return }
        
        // Trigger haptic feedback
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        
        // Start recording (will auto-stop after 4 seconds)
        cameraManager.startRecording()
    }
}

