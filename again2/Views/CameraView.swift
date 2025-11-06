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
    @State private var buttonScale: CGFloat = 1.0
    @State private var showCircularText = false
    @State private var borderOpacity: Double = 1.0
    @State private var textScale: CGFloat = 0.0
    @State private var textRotation: Double = 0.0
    @State private var backgroundOpacity: Double = 0.13
    @State private var isWaitingForRecording = false
    
    var body: some View {
        GeometryReader { geometry in
            let recordingState = cameraManager.recordingState
            let isRecordingActive = recordingState == .recording
            let isPreparingRecording = recordingState == .preparing
            let failureMessage: String? = {
                if case .failed(let message) = recordingState {
                    return message
                }
                return nil
            }()
            ZStack {
                Color.black
                    .ignoresSafeArea()
                
                if cameraManager.isAuthorized {
                    let maxWidth = geometry.size.width
                    let targetWidth = maxWidth
                    let targetHeight = targetWidth * (4.0 / 3.0) // 3:4 aspect ratio

                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(red: 8.0 / 255.0, green: 8.0 / 255.0, blue: 8.0 / 255.0))
                        
                        if let previewLayer = cameraManager.previewLayer {
                            CameraPreviewView(previewLayer: previewLayer)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.white.opacity(0.0), lineWidth: 0)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .highPriorityGesture(
                                    TapGesture(count: 2).onEnded {
                                        let impact = UIImpactFeedbackGenerator(style: .light)
                                        impact.impactOccurred()
                                        cameraManager.toggleCamera()
                                    }
                                )
                        }
                    }
                    .frame(width: targetWidth, height: targetHeight)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .onAppear { cameraManager.startSession() }
                    .onDisappear { cameraManager.stopSession() }
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
                                .padding(.top, 24)
                                .padding(.trailing, 24)
                        }
                    }
                    Spacer()
                }
                
                // Record button / Progress indicator
                VStack {
                    Spacer()
                    
                    if let failureMessage {
                        Text(failureMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                            .padding(.bottom, 8)
                            .transition(.opacity)
                    }

                    // Calculate button size using golden ratio: width / φ³
                    let goldenRatio = 1.618
                    let buttonSize = geometry.size.width / goldenRatio / goldenRatio / goldenRatio

                    // Calculate padding: 4pt from bottom safe area + half button size to center it
                    let bottomSafeArea = geometry.safeAreaInsets.bottom
                    let buttonPadding = bottomSafeArea + 4 + (buttonSize / 2)

                    Button(action: recordButtonTapped) {
                        ZStack {
                            // Outer white ring (box-shadow equivalent: 0 0 0 2.5px white)
                            // Fade out during recording
                            Circle()
                                .fill(Color(white: 1.0))
                                .frame(width: buttonSize + 5, height: buttonSize + 5)
                                .opacity(borderOpacity)

                            // Black border (3px solid black)
                            // Fade out during recording
                            Circle()
                                .fill(Color(white: 0.0))
                                .frame(width: buttonSize, height: buttonSize)
                                .opacity(borderOpacity)

                            // Background - changes to full white during recording
                            Circle()
                                .fill(Color(white: 1.0, opacity: backgroundOpacity))
                                .frame(width: backgroundOpacity > 0.5 ? buttonSize : buttonSize - 6, height: backgroundOpacity > 0.5 ? buttonSize : buttonSize - 6)

                            // "Preparing..." indicator when not warmed up
                            if !cameraManager.isWarmedUp && !cameraManager.isRecording {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            }
                        }
                        .scaleEffect(buttonScale)
                        .overlay(
                            Group {
                                if showCircularText {
                                    CircularText(radius: (buttonSize / 2) + 8)
                                        .scaleEffect(textScale)
                                        .rotationEffect(.degrees(textRotation))
                                }
                            }
                        )
                    }
                    .padding(.bottom, buttonPadding)
                    .disabled(!cameraManager.isWarmedUp || isRecordingActive || isPreparingRecording || showCircularText || isWaitingForRecording)
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
        .onChange(of: cameraManager.recordingState) { newState in
            switch newState {
            case .recording:
                handleRecordingStarted()
            case .idle:
                handleRecordingStopped()
            case .failed(_):
                handleRecordingStopped()
            case .preparing:
                break
            }
        }
        .task {
            await setupCamera()
        }
    }

    private func setupCamera() async {
        let permissionsGranted = await cameraManager.checkPermissions()
        if !permissionsGranted {
            permissionError = "Camera access is required. Please enable it in Settings."
            return
        }
        do {
            try await cameraManager.setupCamera()
        } catch let error as CameraError {
            setupError = error.localizedDescription
        } catch {
            setupError = "An unexpected error occurred while setting up the camera."
        }
    }
    
    private func recordButtonTapped() {
        if case .recording = cameraManager.recordingState { return }
        if case .preparing = cameraManager.recordingState { return }
        guard !showCircularText && !isWaitingForRecording else { return }

        // Haptic feedback
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()

        // Set waiting state to prevent multiple taps
        isWaitingForRecording = true

        // Start recording - animations will begin when isRecording becomes true
        cameraManager.startRecording()
    }
    
    private func handleRecordingStarted() {
        isWaitingForRecording = false

        withAnimation(.linear(duration: 0.1)) {
            borderOpacity = 0.0
            backgroundOpacity = 1.0
        }

        withAnimation(.spring(response: 0.25, dampingFraction: 0.7, blendDuration: 0)) {
            buttonScale = 0.9
        }

        showCircularText = true
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7, blendDuration: 0)) {
            textScale = 1.0
        }

        withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
            textRotation = 360
        }
    }

    private func handleRecordingStopped() {
        isWaitingForRecording = false

        withAnimation(.spring(response: 0.25, dampingFraction: 0.7, blendDuration: 0)) {
            buttonScale = 1.0
            textScale = 0.0
        }
        withAnimation(.linear(duration: 0.1)) {
            borderOpacity = 1.0
            backgroundOpacity = 0.13
        }
        showCircularText = false
        textRotation = 0.0
    }
}

// Circular text view that displays "REC • " around a circle
struct CircularText: View {
    let text = "REC • "
    let radius: CGFloat
    let fontSize: CGFloat = 9

    var body: some View {
        ZStack {
            ForEach(Array(repeatedText.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .font(.system(size: fontSize, weight: .regular, design: .default))
                    .foregroundColor(.white)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(index) * anglePerCharacter))
            }
        }
    }

    private var repeatedText: String {
        String(repeating: text, count: characterCount / text.count + 1)
    }

    private var characterCount: Int {
        let circumference = 2 * .pi * radius
        let charWidth: CGFloat = 6.5 // Approximate width for SF Pro Regular 9px
        return Int(circumference / charWidth)
    }

    private var anglePerCharacter: Double {
        360.0 / Double(characterCount)
    }
}
