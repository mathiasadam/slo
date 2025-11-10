import Foundation
import AVFoundation
import Combine
import UIKit

/// Manages state and playback logic for the day timeline player
class PlayerViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var currentIndex: Int = 0
    @Published var isPlaying: Bool = true
    @Published var playbackProgress: Double = 0.0
    @Published var chunks: [StoryChunk] = []

    // MARK: - Properties

    private var players: [UUID: AVPlayer] = [:]
    private var currentPlayer: AVPlayer?
    private var timeObserver: Any?
    private var endObservers: [UUID: NSObjectProtocol] = [:]

    var currentChunk: StoryChunk? {
        guard currentIndex >= 0 && currentIndex < chunks.count else { return nil }
        return chunks[currentIndex]
    }

    var hasNext: Bool {
        currentIndex < chunks.count - 1
    }

    var hasPrevious: Bool {
        currentIndex > 0
    }

    var progressText: String {
        guard !chunks.isEmpty else { return "0 / 0" }
        return "\(currentIndex + 1) / \(chunks.count)"
    }

    // MARK: - Initialization

    init(chunks: [StoryChunk], startIndex: Int = 0) {
        self.chunks = chunks
        self.currentIndex = max(0, min(startIndex, chunks.count - 1))
        preloadPlayers()
    }

    deinit {
        cleanup()
    }

    // MARK: - Player Management

    private func preloadPlayers() {
        // Preload current and next chunk
        for i in currentIndex..<min(currentIndex + 2, chunks.count) {
            let chunk = chunks[i]
            if players[chunk.id] == nil {
                createPlayer(for: chunk)
            }
        }
    }

    private func createPlayer(for chunk: StoryChunk) {
        let player = AVPlayer(url: chunk.videoURL)
        player.actionAtItemEnd = .none // We'll handle transitions manually
        players[chunk.id] = player

        // Add end observer
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.handleChunkEnded()
        }
        endObservers[chunk.id] = observer

        print("📹 Preloaded player for chunk: \(chunk.id.uuidString)")
    }

    func getPlayer(for chunk: StoryChunk) -> AVPlayer? {
        if let player = players[chunk.id] {
            return player
        }

        // Create on demand if not preloaded
        createPlayer(for: chunk)
        return players[chunk.id]
    }

    // MARK: - Playback Control

    func play() {
        guard let chunk = currentChunk,
              let player = getPlayer(for: chunk) else { return }

        currentPlayer = player
        player.play()
        isPlaying = true
        startProgressObserver()

        print("▶️ Playing chunk \(currentIndex + 1)/\(chunks.count)")
    }

    func pause() {
        currentPlayer?.pause()
        isPlaying = false
        stopProgressObserver()

        print("⏸️ Paused")
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }

        // Haptic feedback
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
    }

    // MARK: - Navigation

    func goToNext() {
        guard hasNext else {
            // Loop back to first
            goToChunk(at: 0)
            return
        }

        goToChunk(at: currentIndex + 1)
    }

    func goToPrevious() {
        guard hasPrevious else { return }
        goToChunk(at: currentIndex - 1)
    }

    func goToChunk(at index: Int) {
        guard index >= 0 && index < chunks.count else { return }

        // Pause current player
        currentPlayer?.pause()
        currentPlayer?.seek(to: .zero)
        stopProgressObserver()

        // Update index
        currentIndex = index
        playbackProgress = 0.0

        // Preload next chunk if needed
        if hasNext {
            let nextChunk = chunks[currentIndex + 1]
            if players[nextChunk.id] == nil {
                createPlayer(for: nextChunk)
            }
        }

        // Play new chunk
        play()

        // Haptic feedback
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()

        print("📍 Jumped to chunk \(currentIndex + 1)/\(chunks.count)")
    }

    // MARK: - Private Helpers

    private func handleChunkEnded() {
        print("✅ Chunk \(currentIndex + 1) finished")

        if hasNext {
            // Auto-advance to next chunk
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.goToNext()
            }
        } else {
            // Loop back to first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.goToChunk(at: 0)
            }
        }
    }

    private func startProgressObserver() {
        guard let player = currentPlayer,
              let duration = player.currentItem?.duration else { return }

        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite && durationSeconds > 0 else { return }

        // Update progress 60 times per second
        let interval = CMTime(seconds: 1.0/60.0, preferredTimescale: 600)

        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let currentSeconds = CMTimeGetSeconds(time)
            if currentSeconds.isFinite && durationSeconds > 0 {
                self?.playbackProgress = currentSeconds / durationSeconds
            }
        }
    }

    private func stopProgressObserver() {
        if let observer = timeObserver {
            currentPlayer?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func cleanup() {
        stopProgressObserver()

        // Remove all observers
        for (_, observer) in endObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        endObservers.removeAll()

        // Cleanup players
        for (_, player) in players {
            player.pause()
        }
        players.removeAll()

        print("🧹 Cleaned up player resources")
    }

    // MARK: - Public Cleanup

    func stop() {
        pause()
        currentPlayer?.seek(to: .zero)
        playbackProgress = 0.0
    }
}
