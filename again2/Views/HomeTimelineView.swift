import SwiftUI

/// Main home view displaying all day timelines in chronological order
struct HomeTimelineView: View {
    @StateObject private var storageManager = TimelineStorageManager.shared
    @State private var timelines: [DayTimeline] = []
    @State private var selectedTimeline: DayTimeline?
    @State private var selectedChunkIndex: Int = 0
    @State private var showPlayer = false
    @State private var showCamera = false
    @State private var isRefreshing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if timelines.isEmpty {
                // Empty state
                EmptyTimelineView()
            } else {
                // Timeline list
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Top padding
                        Color.clear.frame(height: 20)

                        ForEach(timelines) { timeline in
                            DayTimelineSection(
                                timeline: timeline,
                                onChunkTap: { chunk in
                                    handleChunkTap(chunk, in: timeline)
                                }
                            )
                            .id(timeline.id)
                        }

                        // Bottom padding for shutter button area
                        Color.clear.frame(height: 120)
                    }
                }
                .refreshable {
                    await refreshTimelines()
                }
            }

            // Persistent shutter button
            VStack {
                Spacer()

                Button(action: openCamera) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 70, height: 70)

                        Circle()
                            .fill(Color.red)
                            .frame(width: 56, height: 56)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let timeline = selectedTimeline {
                DayTimelinePlayerView(
                    timeline: timeline,
                    startIndex: selectedChunkIndex,
                    onDismiss: {
                        showPlayer = false
                        selectedTimeline = nil
                    }
                )
            }
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            // Refresh timelines after camera dismissal
            loadTimelines()
        }) {
            CameraView()
        }
        .onAppear {
            loadTimelines()
        }
    }

    // MARK: - Actions

    private func loadTimelines() {
        // Get all non-empty timelines from storage
        timelines = TimelineStorageManager.shared.getNonEmptyTimelines()
        print("📱 Loaded \(timelines.count) timelines")

        // Print stats for debugging
        if !timelines.isEmpty {
            TimelineStorageManager.shared.printStorageStats()
        }
    }

    private func refreshTimelines() async {
        isRefreshing = true

        // Clear cache and reload from disk
        TimelineStorageManager.shared.clearCache()

        // Small delay for pull-to-refresh animation
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        loadTimelines()
        isRefreshing = false
    }

    private func handleChunkTap(_ chunk: StoryChunk, in timeline: DayTimeline) {
        print("📹 Tapped chunk: \(chunk.id.uuidString)")
        print("   Duration: \(chunk.formattedDuration)")
        print("   Timestamp: \(chunk.formattedTime)")

        // Find the index of the tapped chunk
        if let index = timeline.chunks.firstIndex(where: { $0.id == chunk.id }) {
            selectedTimeline = timeline
            selectedChunkIndex = index
            showPlayer = true
        }
    }

    private func openCamera() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        showCamera = true
    }
}

#Preview {
    HomeTimelineView()
}
