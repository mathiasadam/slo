//
//  CameraView.swift
//

import SwiftUI
import AVFoundation
import AVKit

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
    @State private var isLivePreviewActive = false
    @State private var storyPlaybackState = StoryPlaybackState()
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    
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

                    VStack(spacing: 8) {
                        if !isLivePreviewActive && !cameraManager.storyClips.isEmpty {
                            StoryProgressStrip(
                                totalClips: cameraManager.storyClips.count,
                                playbackState: storyPlaybackState
                            )
                            .padding(.horizontal, 16)
                        }

                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(red: 8.0 / 255.0, green: 8.0 / 255.0, blue: 8.0 / 255.0))

                            if isLivePreviewActive || isRecordingActive || isPreparingRecording {
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
                                        .simultaneousGesture(
                                            DragGesture(minimumDistance: 10)
                                                .onChanged { value in
                                                    if !isRecordingActive && !isPreparingRecording {
                                                        let translation = value.translation.height
                                                        if translation > 0 {
                                                            isDragging = true
                                                            dragOffset = translation
                                                        }
                                                    }
                                                }
                                                .onEnded { value in
                                                    if !isRecordingActive && !isPreparingRecording {
                                                        let translation = value.translation.height
                                                        let velocity = value.predictedEndLocation.y - value.location.y

                                                        isDragging = false

                                                        if translation > 100 || velocity > 500 {
                                                            let impact = UIImpactFeedbackGenerator(style: .light)
                                                            impact.impactOccurred()
                                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                                dragOffset = 0
                                                            }
                                                            isLivePreviewActive = false
                                                        } else {
                                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                                dragOffset = 0
                                                            }
                                                        }
                                                    }
                                                }
                                        )
                                }
                            } else if !cameraManager.storyClips.isEmpty {
                                StoryPlaybackView(clips: cameraManager.storyClips, playbackState: $storyPlaybackState)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            } else {
                                Text("Take your first clip of the day")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.8))
                                    .multilineTextAlignment(.center)
                                    .padding()
                            }
                        }
                        .frame(width: targetWidth, height: targetHeight)

                        // Metadata below video clip
                        if !isLivePreviewActive && !cameraManager.storyClips.isEmpty {
                            if storyPlaybackState.currentIndex < cameraManager.storyClips.count {
                                StoryMetadataOverlay(clip: cameraManager.storyClips[storyPlaybackState.currentIndex])
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                    .offset(y: dragOffset)
                    .opacity(1.0 - Double(dragOffset / 500))
                    .animation(isDragging ? nil : .default, value: dragOffset)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
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
                
                VStack {
                    HStack {
                        Spacer()
                        if cameraManager.isRecording {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 12, height: 12)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
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

                    // Base shutter metrics
                    let restingSize: CGFloat = 36
                    let fullSize: CGFloat = min(100, geometry.size.width * 0.18)
                    let buttonSize = isLivePreviewActive ? fullSize : restingSize
                    let bottomSafeArea = geometry.safeAreaInsets.bottom
                    let buttonPadding = bottomSafeArea + 8 + buttonSize / 2

                    let buttonDisabled = (isLivePreviewActive && !cameraManager.isWarmedUp) ||
                        isRecordingActive ||
                        isPreparingRecording ||
                        showCircularText ||
                        isWaitingForRecording

                    Button(action: recordButtonTapped) {
                        ZStack {
                            if isLivePreviewActive {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: buttonSize + 5, height: buttonSize + 5)
                                    .opacity(borderOpacity)
                                
                                Circle()
                                    .fill(Color.black)
                                    .frame(width: buttonSize, height: buttonSize)
                                    .opacity(borderOpacity)
                                
                                Circle()
                                    .fill(Color(white: 1.0, opacity: backgroundOpacity))
                                    .frame(width: backgroundOpacity > 0.5 ? buttonSize : buttonSize - 6,
                                           height: backgroundOpacity > 0.5 ? buttonSize : buttonSize - 6)
                                
                                if !cameraManager.isWarmedUp && !cameraManager.isRecording {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                }
                            } else {
                                // Minified version of camera active button
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: buttonSize + 2, height: buttonSize + 2)

                                Circle()
                                    .fill(Color.black)
                                    .frame(width: buttonSize, height: buttonSize)

                                Circle()
                                    .fill(Color(white: 1.0, opacity: 0.13))
                                    .frame(width: buttonSize - 4, height: buttonSize - 4)
                            }
                        }
                        .frame(width: buttonSize + (isLivePreviewActive ? 6 : 0), height: buttonSize + (isLivePreviewActive ? 6 : 0))
                        .scaleEffect(buttonScale, anchor: .center)
                        .overlay(
                            Group {
                                if isLivePreviewActive && showCircularText {
                                    CircularText(radius: (buttonSize / 2) + 8)
                                        .scaleEffect(textScale)
                                        .rotationEffect(.degrees(textRotation))
                                }
                            }
                        )
                    }
                    .padding(.bottom, buttonPadding)
                    .animation(isDragging ? nil : .spring(response: 0.4, dampingFraction: 0.65, blendDuration: 0), value: buttonSize)
                    .animation(isDragging ? nil : .spring(response: 0.4, dampingFraction: 0.65, blendDuration: 0), value: isLivePreviewActive)
                    .disabled(buttonDisabled)

                    if isLivePreviewActive && !cameraManager.isRecording && !cameraManager.isWarmedUp {
                        Text("Preparing camera...")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.top, 8)
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
                    onPost: {
                        cameraManager.keepLatestClipAsStory()
                        showingPreview = false
                        isLivePreviewActive = false
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
        .onChange(of: cameraManager.storyClips) { _ in
            storyPlaybackState = StoryPlaybackState()
        }
        .task {
            await setupCamera()
        }
        .onChange(of: isLivePreviewActive) { isActive in
            if isActive {
                cameraManager.startSession()
            } else {
                cameraManager.stopSession()
            }
        }
        .onDisappear {
            isLivePreviewActive = false
            cameraManager.stopSession()
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
        if !isLivePreviewActive {
            activateLivePreview()
            return
        }

        if case .recording = cameraManager.recordingState { return }
        if case .preparing = cameraManager.recordingState { return }
        guard cameraManager.isWarmedUp else { return }
        guard !showCircularText && !isWaitingForRecording else { return }

        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()

        isWaitingForRecording = true
        cameraManager.startRecording()
    }

    private func activateLivePreview() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        isLivePreviewActive = true
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

struct StoryPlaybackState: Equatable {
    var currentIndex: Int = 0
    var progress: Double = 0.0
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

struct StoryProgressStrip: View {
    let totalClips: Int
    let playbackState: StoryPlaybackState

    private let baseColor = Color.white.opacity(0.13)
    private let fillColor = Color.white

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<totalClips, id: \.self) { index in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(baseColor)
                        Capsule()
                            .fill(fillColor)
                            .frame(width: geometry.size.width * fillAmount(for: index))
                    }
                }
                .frame(height: 2)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 2)
    }

    private func fillAmount(for index: Int) -> CGFloat {
        if index < playbackState.currentIndex {
            return 1.0
        } else if index == playbackState.currentIndex {
            return CGFloat(min(max(playbackState.progress, 0), 1))
        } else {
            return 0.0
        }
    }
}

struct StoryPlaybackView: UIViewControllerRepresentable {
    let clips: [CameraManager.StoryClip]
    @Binding var playbackState: StoryPlaybackState

    func makeCoordinator() -> Coordinator {
        Coordinator(playbackState: $playbackState)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill
        controller.view.backgroundColor = .black
        context.coordinator.attach(controller: controller)
        context.coordinator.updateClips(clips)
        context.coordinator.setupGestures()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        context.coordinator.updateClips(clips)
    }

    final class Coordinator: NSObject {
        private var controller: AVPlayerViewController?
        private let player = AVPlayer()
        private var clips: [CameraManager.StoryClip] = []
        private var currentIndex = 0
        private var endObserver: NSObjectProtocol?
        private var timeObserver: Any?
        private var playbackState: Binding<StoryPlaybackState>
        private var isPaused = false

        init(playbackState: Binding<StoryPlaybackState>) {
            self.playbackState = playbackState
            super.init()
        }

        func attach(controller: AVPlayerViewController) {
            self.controller = controller
            controller.player = player
        }

        func setupGestures() {
            guard let view = controller?.view else { return }

            // Left tap gesture (previous clip)
            let leftTap = UITapGestureRecognizer(target: self, action: #selector(handleLeftTap))
            leftTap.delegate = self
            view.addGestureRecognizer(leftTap)

            // Right tap gesture (next clip)
            let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleRightTap))
            rightTap.delegate = self
            view.addGestureRecognizer(rightTap)

            // Long press gesture (pause/resume)
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
            longPress.minimumPressDuration = 0.2
            longPress.delegate = self
            view.addGestureRecognizer(longPress)
        }

        @objc private func handleLeftTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)

            // Only handle if tap is in left 50%
            if location.x < view.bounds.width / 2 {
                previousClip()
            }
        }

        @objc private func handleRightTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)

            // Only handle if tap is in right 50%
            if location.x >= view.bounds.width / 2 {
                nextClip()
            }
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                // Pause on press
                player.pause()
                isPaused = true
            case .ended, .cancelled:
                // Resume on release
                if isPaused {
                    player.play()
                    isPaused = false
                }
            default:
                break
            }
        }

        private func previousClip() {
            guard !clips.isEmpty else { return }

            // If we're more than 0.5s into current clip, restart it
            if let currentTime = player.currentItem?.currentTime(),
               CMTimeGetSeconds(currentTime) > 0.5 {
                player.seek(to: .zero)
                player.play()
                playbackState.wrappedValue = StoryPlaybackState(currentIndex: currentIndex, progress: 0)
            } else {
                // Go to previous clip
                currentIndex = currentIndex > 0 ? currentIndex - 1 : clips.count - 1
                playCurrentClip()
            }
        }

        private func nextClip() {
            guard !clips.isEmpty else { return }
            currentIndex = (currentIndex + 1) % clips.count
            playCurrentClip()
        }

        func updateClips(_ newClips: [CameraManager.StoryClip]) {
            guard newClips != clips else {
                if clips.isEmpty {
                    playbackState.wrappedValue = StoryPlaybackState()
                }
                return
            }

            clips = newClips
            currentIndex = 0
            removeObserver()
            removeTimeObserver()

            guard !clips.isEmpty else {
                player.replaceCurrentItem(with: nil)
                playbackState.wrappedValue = StoryPlaybackState()
                return
            }

            playCurrentClip()
        }

        private func playCurrentClip() {
            guard !clips.isEmpty else { return }
            let clip = clips[currentIndex]
            let item = AVPlayerItem(url: clip.url)
            player.replaceCurrentItem(with: item)
            player.play()

            removeObserver()
             removeTimeObserver()
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.advance()
            }
            addTimeObserver(for: item)
            playbackState.wrappedValue = StoryPlaybackState(currentIndex: currentIndex, progress: 0)
        }

        private func advance() {
            guard !clips.isEmpty else { return }
            currentIndex = (currentIndex + 1) % clips.count
            playCurrentClip()
        }

        private func removeObserver() {
            if let observer = endObserver {
                NotificationCenter.default.removeObserver(observer)
                endObserver = nil
            }
        }

        private func addTimeObserver(for item: AVPlayerItem) {
            let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self = self else { return }
                let durationSeconds = CMTimeGetSeconds(item.duration)
                guard durationSeconds.isFinite && durationSeconds > 0 else { return }
                let currentSeconds = CMTimeGetSeconds(time)
                guard currentSeconds.isFinite else { return }
                let progress = min(max(currentSeconds / durationSeconds, 0), 1)
                var state = self.playbackState.wrappedValue
                state.currentIndex = self.currentIndex
                state.progress = progress
                self.playbackState.wrappedValue = state
            }
        }

        private func removeTimeObserver() {
            if let observer = timeObserver {
                player.removeTimeObserver(observer)
                timeObserver = nil
            }
        }

        deinit {
            removeObserver()
            removeTimeObserver()
        }
    }
}

// MARK: - UIGestureRecognizerDelegate
extension StoryPlaybackView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow tap gestures to work together, but long press should be independent
        if gestureRecognizer is UILongPressGestureRecognizer || otherGestureRecognizer is UILongPressGestureRecognizer {
            return false
        }
        return true
    }
}

// MARK: - Story Metadata Overlay
struct StoryMetadataOverlay: View {
    let clip: CameraManager.StoryClip
    @AppStorage("username") private var storedUsername: String = ""

    private var username: String {
        storedUsername.isEmpty ? "Untitled" : storedUsername
    }

    private var captureTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: clip.createdAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(username)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)

                Spacer()

                Text(captureTime)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.5))
            }

            if let location = clip.location {
                Text(location)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
