import Foundation
import AVFoundation
import UIKit
import CoreImage

/// Utility class for video processing operations
class VideoProcessor {

    // MARK: - Thumbnail Generation

    /// Generates a thumbnail image from the first frame of a video
    /// - Parameters:
    ///   - videoURL: URL to the video file
    ///   - size: Desired size of the thumbnail (defaults to 1080x1920 for portrait)
    /// - Returns: URL to the saved thumbnail image, or nil if generation fails
    static func generateThumbnail(from videoURL: URL, size: CGSize = CGSize(width: 1080, height: 1920)) async -> URL? {
        let asset = AVAsset(url: videoURL)

        // Create image generator
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = size

        do {
            // Get first frame at time zero
            let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
            let image = UIImage(cgImage: cgImage)

            // Save thumbnail to disk
            let thumbnailURL = try saveThumbnail(image, for: videoURL)
            return thumbnailURL
        } catch {
            print("❌ Failed to generate thumbnail: \(error.localizedDescription)")
            return nil
        }
    }

    /// Saves a thumbnail image to disk next to the video file
    /// - Parameters:
    ///   - image: The UIImage to save
    ///   - videoURL: The video URL (used to determine save location)
    /// - Returns: URL to the saved thumbnail
    private static func saveThumbnail(_ image: UIImage, for videoURL: URL) throws -> URL {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw VideoProcessorError.thumbnailGenerationFailed
        }

        // Create thumbnail URL in same directory as video
        let thumbnailURL = videoURL
            .deletingPathExtension()
            .appendingPathExtension("jpg")

        try imageData.write(to: thumbnailURL)

        print("✅ Thumbnail saved: \(thumbnailURL.lastPathComponent)")
        return thumbnailURL
    }

    // MARK: - Video Validation

    /// Validates that a video file exists and is readable
    /// - Parameter url: URL to the video file
    /// - Returns: `true` if video is valid, `false` otherwise
    static func validateVideo(at url: URL) -> Bool {
        // Check file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ Video does not exist at: \(url.path)")
            return false
        }

        // Check file is readable
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            print("❌ Video is not readable at: \(url.path)")
            return false
        }

        return true
    }

    /// Gets the duration of a video file
    /// - Parameter url: URL to the video file
    /// - Returns: Duration in seconds, or nil if unable to determine
    static func getVideoDuration(from url: URL) async -> TimeInterval? {
        let asset = AVAsset(url: url)

        do {
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            print("❌ Failed to get video duration: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - File Operations

    /// Copies a video file to a new location
    /// - Parameters:
    ///   - sourceURL: Source video URL
    ///   - destinationURL: Destination URL
    /// - Returns: The destination URL on success
    @discardableResult
    static func copyVideo(from sourceURL: URL, to destinationURL: URL) throws -> URL {
        let fileManager = FileManager.default

        // Ensure source exists
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw VideoProcessorError.sourceFileNotFound
        }

        // Create destination directory if needed
        let destinationDir = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        // Remove existing file if it exists
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        // Copy the file
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        print("✅ Video copied to: \(destinationURL.lastPathComponent)")
        return destinationURL
    }

    /// Deletes a video and its associated thumbnail
    /// - Parameter videoURL: URL to the video file
    static func deleteVideo(at videoURL: URL) throws {
        let fileManager = FileManager.default

        // Delete video
        if fileManager.fileExists(atPath: videoURL.path) {
            try fileManager.removeItem(at: videoURL)
            print("🗑️ Deleted video: \(videoURL.lastPathComponent)")
        }

        // Delete thumbnail if it exists
        let thumbnailURL = videoURL.deletingPathExtension().appendingPathExtension("jpg")
        if fileManager.fileExists(atPath: thumbnailURL.path) {
            try fileManager.removeItem(at: thumbnailURL)
            print("🗑️ Deleted thumbnail: \(thumbnailURL.lastPathComponent)")
        }
    }

    // MARK: - Utility

    /// Gets the size of a video file in bytes
    /// - Parameter url: URL to the video file
    /// - Returns: File size in bytes, or nil if unable to determine
    static func getVideoFileSize(at url: URL) -> Int64? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64
        } catch {
            print("❌ Failed to get file size: \(error.localizedDescription)")
            return nil
        }
    }

    /// Formats file size for display
    /// - Parameter bytes: Size in bytes
    /// - Returns: Formatted string (e.g., "2.5 MB")
    static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Errors

enum VideoProcessorError: Error, LocalizedError {
    case thumbnailGenerationFailed
    case sourceFileNotFound
    case destinationWriteFailed
    case invalidVideoFile

    var errorDescription: String? {
        switch self {
        case .thumbnailGenerationFailed:
            return "Failed to generate thumbnail from video"
        case .sourceFileNotFound:
            return "Source video file not found"
        case .destinationWriteFailed:
            return "Failed to write video to destination"
        case .invalidVideoFile:
            return "Video file is invalid or corrupted"
        }
    }
}
