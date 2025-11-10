import SwiftUI

/// Displays a thumbnail for a story chunk with duration badge
struct ChunkThumbnailView: View {
    let chunk: StoryChunk
    let onTap: () -> Void

    @State private var thumbnailImage: UIImage?
    @State private var isPressed = false

    var body: some View {
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            onTap()
        }) {
            ZStack(alignment: .bottomTrailing) {
                // Thumbnail image or placeholder
                if let image = thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(3/4, contentMode: .fill)
                        .frame(width: 120, height: 160)
                        .clipped()
                } else {
                    // Placeholder while loading
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 120, height: 160)
                        .overlay(
                            ProgressView()
                                .tint(.white)
                        )
                }

                // Duration badge
                Text(chunk.formattedDuration)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white)
                    )
                    .padding(6)
            }
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        // Load thumbnail from URL if available
        guard let thumbnailURL = chunk.thumbnailURL else {
            // If no thumbnail, generate from video
            Task {
                if let generatedURL = await VideoProcessor.generateThumbnail(from: chunk.videoURL) {
                    loadImage(from: generatedURL)
                }
            }
            return
        }

        loadImage(from: thumbnailURL)
    }

    private func loadImage(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                DispatchQueue.main.async {
                    self.thumbnailImage = image
                }
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        HStack(spacing: 12) {
            ChunkThumbnailView(
                chunk: StoryChunk(
                    videoURL: URL(fileURLWithPath: "/tmp/test.mp4"),
                    duration: 1.5
                ),
                onTap: { print("Tapped") }
            )

            ChunkThumbnailView(
                chunk: StoryChunk(
                    videoURL: URL(fileURLWithPath: "/tmp/test2.mp4"),
                    duration: 2.3
                ),
                onTap: { print("Tapped") }
            )
        }
        .padding()
    }
}
