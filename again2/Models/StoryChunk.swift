import Foundation
import AVFoundation

/// Represents a single video chunk in a day's timeline
struct StoryChunk: Identifiable, Codable, Equatable {
    /// Unique identifier for the story chunk
    let id: UUID

    /// Local file path to the video
    let videoURL: URL

    /// Exact timestamp when the video was posted
    let timestamp: Date

    /// Duration of the video in seconds
    let duration: TimeInterval

    /// Optional thumbnail image path
    let thumbnailURL: URL?

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        videoURL: URL,
        timestamp: Date = Date(),
        duration: TimeInterval,
        thumbnailURL: URL? = nil
    ) {
        self.id = id
        self.videoURL = videoURL
        self.timestamp = timestamp
        self.duration = duration
        self.thumbnailURL = thumbnailURL
    }

    // MARK: - Helper Methods

    /// Checks if the video file exists at the stored URL
    var videoExists: Bool {
        FileManager.default.fileExists(atPath: videoURL.path)
    }

    /// Checks if the thumbnail exists (if one was set)
    var thumbnailExists: Bool {
        guard let thumbnailURL = thumbnailURL else { return false }
        return FileManager.default.fileExists(atPath: thumbnailURL.path)
    }

    /// Returns a formatted time string for when this chunk was posted (e.g., "2:34 PM")
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    /// Returns a formatted duration string (e.g., "1.5s")
    var formattedDuration: String {
        String(format: "%.1fs", duration)
    }

    // MARK: - Static Factory Methods

    /// Creates a StoryChunk from a video URL, automatically calculating duration
    static func create(from videoURL: URL, timestamp: Date = Date()) async throws -> StoryChunk {
        let asset = AVAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        return StoryChunk(
            videoURL: videoURL,
            timestamp: timestamp,
            duration: durationSeconds
        )
    }
}
