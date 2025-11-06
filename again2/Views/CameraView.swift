//
//  CameraView.swift
//

import SwiftUI
import AVFoundation

struct CameraView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var permissionError: String?
    @State private var setupError: String?
    @State private var showingPreview = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .ignoresSafeArea()
                
                if cameraManager.isAuthorized {
                    if let previewLayer = cameraManager.previewLayer {
                        // Constrain preview to 3:4 (width:height) and center it
                        let maxWidth = geometry.size.width
                        let targetWidth = maxWidth
                        let targetHeight = targetWidth * (4.0 / 3.0) // 3:4 aspect ratio
                        
                        CameraPreviewView(previewLayer: previewLayer)
                            .frame(width: targetWidth, height: targetHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white.opacity(0.0), lineWidth: 0) // no visible stroke; keeps edge crisp if needed
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .highPriorityGesture(
                                TapGesture(count: 2).onEnded {
                                    let impact = UIImpactFeedbackGenerator(style: .light)
                                    impact.impactOccurred()
                                    cameraManager.toggleCamera()
                                }
                            )
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            .onAppear {
                                cameraManager.startSession()
                            }
                            .onDisappear {
                                cameraManager.stopSession()
                            }
                    } else {
                        ProgressView()
                            .tint(.white)
                            .onAppear { cameraManager.startSession() }
                            .onDisappear { cameraManager.stopSession() }
                    }
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
                
                // Top-right recording indicator
                VStack {
                    HStack {
                        Spacer()
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
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.3), lineWidth: 6)
                                .frame(width: 80, height: 80)
                            
                            Circle()
                                .trim(from: 0, to: cameraManager.recordingProgress)
                                .stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                .frame(width: 80, height: 80)
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.016), value: cameraManager.recordingProgress)
                            
                            Text(String(format: "%.1f", (1.0 - cameraManager.recordingProgress) * 1.5))
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.bottom, 40)
                    } else {
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
        }
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
        let permissionsGranted = await cameraManager.checkPermissions()
        if !permissionsGranted {
            permissionError = "Camera and microphone access are required. Please enable them in Settings."
            return
        }
        do {
            try cameraManager.setupCamera()
        } catch let error as CameraError {
            setupError = error.localizedDescription
        } catch {
            setupError = "An unexpected error occurred while setting up the camera."
        }
    }
    
    private func recordButtonTapped() {
        guard !cameraManager.isRecording else { return }
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        cameraManager.startRecording()
    }
}

