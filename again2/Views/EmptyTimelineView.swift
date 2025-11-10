import SwiftUI

/// Empty state view shown when no timelines exist
struct EmptyTimelineView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 2)
                    .frame(width: 120, height: 120)

                Image(systemName: "video.fill")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(.white.opacity(0.6))
            }

            // Message
            VStack(spacing: 12) {
                Text("No moments yet")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)

                Text("Tap the button below to capture\nyour first moment")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Spacer()

            // Arrow pointing down to shutter button
            VStack(spacing: 8) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

#Preview {
    EmptyTimelineView()
}
