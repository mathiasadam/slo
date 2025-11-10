import SwiftUI
import AVKit

/// Full-screen video player for a day's timeline with swipe navigation and auto-play
struct DayTimelinePlayerView: View {
    let timeline: DayTimeline
    let startIndex: Int
    let onDismiss: () -> Void

    @StateObject private var viewModel: PlayerViewModel
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    init(timeline: DayTimeline, startIndex: Int = 0, onDismiss: @escaping () -> Void) {
        self.timeline = timeline
        self.startIndex = startIndex
        self.onDismiss = onDismiss
        _viewModel = StateObject(wrappedValue: PlayerViewModel(chunks: timeline.chunks, startIndex: startIndex))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Video player
            if let chunk = viewModel.currentChunk,
               let player = viewModel.getPlayer(for: chunk) {
                InteractiveVideoPlayerView(player: player) {
                    viewModel.togglePlayPause()
                }
                .ignoresSafeArea()
            }

            // Swipe down gesture overlay
            VStack {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 100)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if value.translation.height > 0 {
                                    dragOffset = value.translation.height
                                    isDragging = true
                                }
                            }
                            .onEnded { value in
                                if value.translation.height > 100 {
                                    // Dismiss if dragged down enough
                                    viewModel.stop()
                                    onDismiss()
                                } else {
                                    // Spring back
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        dragOffset = 0
                                    }
                                }
                                isDragging = false
                            }
                    )

                Spacer()
            }

            // UI Overlays
            VStack {
                // Top bar with progress and close button
                HStack {
                    // Progress counter
                    Text(viewModel.progressText)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.5))
                        )

                    Spacer()

                    // Close button
                    Button(action: {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        viewModel.stop()
                        onDismiss()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.5))
                            )
                    }
                }
                .padding(.top, 56)
                .padding(.horizontal, 20)

                Spacer()

                // Progress bar at bottom
                VStack(spacing: 8) {
                    // Progress dots
                    HStack(spacing: 4) {
                        ForEach(0..<viewModel.chunks.count, id: \.self) { index in
                            if index == viewModel.currentIndex {
                                // Current chunk - animated progress bar
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        // Background
                                        Capsule()
                                            .fill(Color.white.opacity(0.3))

                                        // Progress fill
                                        Capsule()
                                            .fill(Color.white)
                                            .frame(width: geometry.size.width * viewModel.playbackProgress)
                                    }
                                }
                                .frame(height: 3)
                            } else if index < viewModel.currentIndex {
                                // Completed chunks
                                Capsule()
                                    .fill(Color.white)
                                    .frame(height: 3)
                            } else {
                                // Upcoming chunks
                                Capsule()
                                    .fill(Color.white.opacity(0.3))
                                    .frame(height: 3)
                            }
                        }
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 20)

                    // Date label
                    Text(timeline.formattedDate)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.bottom, 8)
                }
                .padding(.bottom, 40)
            }

            // Left/right swipe areas (invisible buttons)
            HStack(spacing: 0) {
                // Previous button (left third)
                Button(action: {
                    viewModel.goToPrevious()
                }) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .frame(maxWidth: .infinity)
                .opacity(viewModel.hasPrevious ? 1 : 0.5)
                .allowsHitTesting(viewModel.hasPrevious)

                // Center (tap to pause/play) - handled by video player

                Spacer()
                    .frame(maxWidth: .infinity)

                // Next button (right third)
                Button(action: {
                    viewModel.goToNext()
                }) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .frame(maxWidth: .infinity)
            }
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        if abs(value.translation.width) > abs(value.translation.height) {
                            if value.translation.width < 0 && viewModel.hasNext {
                                // Swiped left - next
                                viewModel.goToNext()
                            } else if value.translation.width > 0 && viewModel.hasPrevious {
                                // Swiped right - previous
                                viewModel.goToPrevious()
                            }
                        }
                    }
            )
        }
        .offset(y: dragOffset)
        .animation(.interactiveSpring(), value: dragOffset)
        .statusBar(hidden: true)
        .onAppear {
            viewModel.play()
        }
        .onDisappear {
            viewModel.stop()
        }
    }
}

#Preview {
    DayTimelinePlayerView(
        timeline: {
            var timeline = DayTimeline.today()
            timeline.addChunk(StoryChunk(
                videoURL: URL(fileURLWithPath: "/tmp/test1.mp4"),
                duration: 1.5
            ))
            timeline.addChunk(StoryChunk(
                videoURL: URL(fileURLWithPath: "/tmp/test2.mp4"),
                duration: 2.0
            ))
            timeline.addChunk(StoryChunk(
                videoURL: URL(fileURLWithPath: "/tmp/test3.mp4"),
                duration: 1.0
            ))
            return timeline
        }(),
        startIndex: 0,
        onDismiss: {
            print("Dismissed")
        }
    )
}
