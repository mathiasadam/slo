import SwiftUI

/// Displays a single day's timeline with date header and horizontal chunk strip
struct DayTimelineSection: View {
    let timeline: DayTimeline
    let onChunkTap: (StoryChunk) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Date header
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(timeline.formattedDate)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                // Chunk count
                if timeline.chunkCount > 0 {
                    Text("\(timeline.chunkCount) moment\(timeline.chunkCount == 1 ? "" : "s")")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }

                Spacer()

                // Total duration
                if timeline.totalDuration > 0 {
                    Text(timeline.formattedTotalDuration)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 20)

            // Horizontal scrolling chunks
            if timeline.isEmpty {
                // Empty day state
                Text("No moments captured")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 40)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // Leading padding
                        Color.clear.frame(width: 8)

                        ForEach(timeline.chunks) { chunk in
                            ChunkThumbnailView(chunk: chunk) {
                                onChunkTap(chunk)
                            }
                        }

                        // Trailing padding
                        Color.clear.frame(width: 8)
                    }
                    .padding(.horizontal, 12)
                }
            }

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 20)
                .padding(.top, 8)
        }
        .padding(.vertical, 12)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        ScrollView {
            VStack(spacing: 0) {
                // Today with chunks
                DayTimelineSection(
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
                        return timeline
                    }(),
                    onChunkTap: { chunk in
                        print("Tapped chunk: \(chunk.id)")
                    }
                )

                // Yesterday empty
                DayTimelineSection(
                    timeline: {
                        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
                        return DayTimeline.forDate(yesterday)
                    }(),
                    onChunkTap: { chunk in
                        print("Tapped chunk: \(chunk.id)")
                    }
                )
            }
        }
    }
}
