import SwiftUI

/// Action buttons shown after capturing a video
struct PostCaptureActionsView: View {
    let onRetake: () -> Void
    let onPost: () -> Void

    @State private var retakePressed = false
    @State private var postPressed = false

    var body: some View {
        VStack {
            Spacer()

            HStack(spacing: 0) {
                // Retake button
                Button(action: handleRetake) {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundColor(.white)

                        Text("Retake")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(
                        RoundedRectangle(cornerRadius: 0)
                            .fill(retakePressed ? Color.white.opacity(0.2) : Color.clear)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            retakePressed = true
                        }
                        .onEnded { _ in
                            retakePressed = false
                        }
                )

                // Vertical divider
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1)

                // Post button
                Button(action: handlePost) {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(.black)

                        Text("Post")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.black)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(
                        RoundedRectangle(cornerRadius: 0)
                            .fill(postPressed ? Color.white.opacity(0.8) : Color.white)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            postPressed = true
                        }
                        .onEnded { _ in
                            postPressed = false
                        }
                )
            }
            .background(Color.black)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func handleRetake() {
        // Light haptic feedback for destructive action
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()

        // Small delay to feel the haptic before transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            onRetake()
        }
    }

    private func handlePost() {
        // Medium haptic feedback for primary action
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()

        // Small delay to feel the haptic before transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            onPost()
        }
    }
}

#Preview {
    ZStack {
        Color.gray
            .ignoresSafeArea()

        PostCaptureActionsView(
            onRetake: { print("Retake tapped") },
            onPost: { print("Post tapped") }
        )
    }
}
