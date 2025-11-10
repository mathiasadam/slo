import SwiftUI
import AVKit
import AVFoundation

struct PreviewView: View {
    let videoURL: URL
    let onRetake: () -> Void
    let onPost: () -> Void

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var showShareSheet = false
    @State private var playbackObserver: NSObjectProtocol?
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .ignoresSafeArea()
                
                // 3:4 playback area centered on screen
                if let player = player {
                    let targetWidth = geometry.size.width
                    let targetHeight = targetWidth * (4.0 / 3.0)
                    
                    CustomVideoPlayer(player: player)
                        .frame(width: targetWidth, height: targetHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(0.0), lineWidth: 0)
                        )
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                } else {
                    ProgressView()
                        .tint(.white)
                }
                
                // Action buttons
                VStack {
                    Spacer()
                    
                    HStack(spacing: 50) {
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

                        // Post button
                        Button(action: {
                            player?.pause()
                            onPost()
                        }) {
                            VStack(spacing: 8) {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white)
                                Text("Post")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                            }
                        }
                        
                        // Share button
                        Button(action: {
                            showShareSheet = true
                        }) {
                            VStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white)
                                Text("Share")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .padding(.bottom, 60)
                }
            }
            .onAppear {
                setupPlayer()
            }
            .onDisappear {
                player?.pause()
                player = nil
                if let observer = playbackObserver {
                    NotificationCenter.default.removeObserver(observer)
                    playbackObserver = nil
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: [videoURL])
            }
        }
    }
    
    private func setupPlayer() {
        guard player == nil else { return }
        
        if let observer = playbackObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackObserver = nil
        }
        
        print("Setting up player with URL: \(videoURL)")
        
        if !FileManager.default.fileExists(atPath: videoURL.path) {
            print("Warning: Video file does not exist at path: \(videoURL.path)")
            return
        }
        
        let playerItem = AVPlayerItem(url: videoURL)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.currentItem?.audioTimePitchAlgorithm = .spectral
        
        self.player = newPlayer
        newPlayer.play()
        
        playbackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak newPlayer] _ in
            newPlayer?.seek(to: .zero)
            newPlayer?.play()
        }
    }
}

// SwiftUI wrapper for AVPlayer with custom controls
struct CustomVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill
        // Ensure the view hierarchy respects rounded corners when clipped by SwiftUI
        controller.view.clipsToBounds = true
        controller.view.layer.cornerCurve = .continuous
        controller.view.layer.cornerRadius = 6
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
        uiViewController.view.clipsToBounds = true
        uiViewController.view.layer.cornerCurve = .continuous
        uiViewController.view.layer.cornerRadius = 6
    }
}

// SwiftUI wrapper for UIActivityViewController
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)

        // Exclude some activity types if desired (optional)
        controller.excludedActivityTypes = [
            .addToReadingList,
            .assignToContact,
            .markupAsPDF,
            .openInIBooks,
            .print
        ]

        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // No updates needed
    }
}
