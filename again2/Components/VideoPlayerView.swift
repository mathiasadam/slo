import SwiftUI
import AVKit

/// Video player component that displays a single video with AVPlayer
struct VideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
    }
}

/// Wrapper view with tap gesture for pause/play
struct InteractiveVideoPlayerView: View {
    let player: AVPlayer
    let onTap: () -> Void

    var body: some View {
        VideoPlayerView(player: player)
            .ignoresSafeArea()
            .onTapGesture {
                onTap()
            }
    }
}
