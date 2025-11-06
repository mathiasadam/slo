import SwiftUI
import AVKit
import AVFoundation

struct PreviewView: View {
    let videoURL: URL
    let onRetake: () -> Void
    let onSend: () -> Void
    
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            // Video player
            if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear {
                        setupPlayer()
                    }
            }
            
            // Action buttons
            VStack {
                Spacer()
                
                HStack(spacing: 60) {
                    // Retake button
                    Button(action: {
                        player?.pause()
                        onRetake()
                    }) {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 30))
                                .foregroundColor(.white)
                            Text("Retake")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }
                    
                    // Send button
                    Button(action: {
                        player?.pause()
                        onSend()
                    }) {
                        VStack(spacing: 8) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 30))
                                .foregroundColor(.white)
                            Text("Send")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
    
    private func setupPlayer() {
        guard player == nil else { return }
        
        let playerItem = AVPlayerItem(url: videoURL)
        let newPlayer = AVPlayer(playerItem: playerItem)
        
        // Enable audio with natural pitch at normal speed
        newPlayer.currentItem?.audioTimePitchAlgorithm = .spectral
        
        // Play at normal speed (slow motion is already in the processed video)
        newPlayer.play()
        
        self.player = newPlayer
        
        // Setup looping observer
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak newPlayer] _ in
            // Loop back to start
            newPlayer?.seek(to: .zero)
            newPlayer?.play()
        }
    }
}

// SwiftUI wrapper for AVPlayer with custom controls
struct VideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // No updates needed
    }
}

