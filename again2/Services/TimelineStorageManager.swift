import Foundation
import AVFoundation
import Combine

/// Manages storage and retrieval of day-based timelines
class TimelineStorageManager: ObservableObject {

    // MARK: - Singleton

    static let shared = TimelineStorageManager()

    private init() {
        setupStorageDirectory()
        loadAllTimelinesFromDisk()
    }

    // MARK: - Properties

    /// In-memory cache of loaded timelines, keyed by date string (yyyy-MM-dd)
    private var timelineCache: [String: DayTimeline] = [:]

    /// Serial queue for thread-safe file operations
    private let fileQueue = DispatchQueue(label: "com.timeloop.storage", qos: .userInitiated)

    /// Root directory for all timeline storage
    private lazy var timelinesDirectory: URL = {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDir.appendingPathComponent("timelines")
    }()

    /// Date formatter for directory names (yyyy-MM-dd)
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Public API

    /// Saves a video chunk to the timeline for a specific date
    /// - Parameters:
    ///   - videoURL: Temporary URL of the recorded video
    ///   - timestamp: Exact timestamp when video was posted
    /// - Returns: The created StoryChunk, or nil if save failed
    @discardableResult
    func saveChunk(videoURL: URL, timestamp: Date = Date()) async -> StoryChunk? {
        return await withCheckedContinuation { continuation in
            fileQueue.async {
                do {
                    // Create directory structure for this day
                    let dayDir = self.dayDirectory(for: timestamp)
                    let chunksDir = dayDir.appendingPathComponent("chunks")
                    try FileManager.default.createDirectory(at: chunksDir, withIntermediateDirectories: true)

                    // Generate unique filename
                    let chunkID = UUID()
                    let destinationURL = chunksDir.appendingPathComponent("chunk-\(chunkID.uuidString).mp4")

                    // Copy video to permanent storage
                    try VideoProcessor.copyVideo(from: videoURL, to: destinationURL)

                    // Generate thumbnail asynchronously
                    Task {
                        let thumbnailURL = await VideoProcessor.generateThumbnail(from: destinationURL)

                        // Get video duration
                        let duration = await VideoProcessor.getVideoDuration(from: destinationURL) ?? 1.5

                        // Create StoryChunk
                        let chunk = StoryChunk(
                            id: chunkID,
                            videoURL: destinationURL,
                            timestamp: timestamp,
                            duration: duration,
                            thumbnailURL: thumbnailURL
                        )

                        // Add to timeline
                        self.addChunkToTimeline(chunk, date: timestamp)

                        // Save metadata
                        self.saveMetadata(for: timestamp)

                        print("✅ Saved chunk: \(chunk.id.uuidString)")
                        print("   Video: \(destinationURL.lastPathComponent)")
                        print("   Duration: \(String(format: "%.1fs", duration))")
                        if let thumbURL = thumbnailURL {
                            print("   Thumbnail: \(thumbURL.lastPathComponent)")
                        }

                        continuation.resume(returning: chunk)
                    }
                } catch {
                    print("❌ Failed to save chunk: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Gets the timeline for a specific date
    /// - Parameter date: The date to retrieve
    /// - Returns: DayTimeline if it exists, nil otherwise
    func getTimeline(for date: Date) -> DayTimeline? {
        let dateKey = dateKey(for: date)

        // Check cache first
        if let cached = timelineCache[dateKey] {
            return cached
        }

        // Load from disk
        return loadTimeline(for: date)
    }

    /// Gets all timelines, sorted newest first
    /// - Returns: Array of all timelines
    func getAllTimelines() -> [DayTimeline] {
        return timelineCache.values
            .sorted { $0.date > $1.date }
    }

    /// Gets only timelines that have chunks
    /// - Returns: Array of non-empty timelines
    func getNonEmptyTimelines() -> [DayTimeline] {
        return getAllTimelines().filter { !$0.isEmpty }
    }

    /// Gets or creates today's timeline
    /// - Returns: DayTimeline for today
    func getTodayTimeline() -> DayTimeline {
        let today = Date()
        let dateKey = dateKey(for: today)

        if let existing = timelineCache[dateKey] {
            return existing
        }

        // Create new timeline for today
        let timeline = DayTimeline.today()
        timelineCache[dateKey] = timeline
        return timeline
    }

    /// Deletes a specific chunk from a timeline
    /// - Parameters:
    ///   - chunkId: ID of the chunk to delete
    ///   - date: Date of the timeline
    func deleteChunk(withId chunkId: UUID, from date: Date) async {
        await withCheckedContinuation { continuation in
            fileQueue.async {
                do {
                    let dateKey = self.dateKey(for: date)
                    guard var timeline = self.timelineCache[dateKey] else {
                        continuation.resume()
                        return
                    }

                    // Find the chunk
                    guard let chunk = timeline.chunks.first(where: { $0.id == chunkId }) else {
                        continuation.resume()
                        return
                    }

                    // Delete video and thumbnail files
                    try VideoProcessor.deleteVideo(at: chunk.videoURL)

                    // Remove from timeline
                    timeline.removeChunk(withId: chunkId)
                    self.timelineCache[dateKey] = timeline

                    // Save updated metadata
                    self.saveMetadata(for: date)

                    print("✅ Deleted chunk: \(chunkId.uuidString)")
                    continuation.resume()
                } catch {
                    print("❌ Failed to delete chunk: \(error.localizedDescription)")
                    continuation.resume()
                }
            }
        }
    }

    /// Clears all cached timelines (forces reload from disk)
    func clearCache() {
        fileQueue.async {
            self.timelineCache.removeAll()
            self.loadAllTimelinesFromDisk()
        }
    }

    // MARK: - Private Helpers

    /// Sets up the base storage directory
    private func setupStorageDirectory() {
        do {
            try FileManager.default.createDirectory(at: timelinesDirectory, withIntermediateDirectories: true)
            print("📁 Timelines directory: \(timelinesDirectory.path)")
        } catch {
            print("❌ Failed to create timelines directory: \(error.localizedDescription)")
        }
    }

    /// Returns the directory for a specific day
    private func dayDirectory(for date: Date) -> URL {
        let dateString = dateFormatter.string(from: normalizeToStartOfDay(date: date))
        return timelinesDirectory.appendingPathComponent(dateString)
    }

    /// Returns the metadata file URL for a specific day
    private func metadataURL(for date: Date) -> URL {
        return dayDirectory(for: date).appendingPathComponent("metadata.json")
    }

    /// Returns a cache key for a date
    private func dateKey(for date: Date) -> String {
        return dateFormatter.string(from: normalizeToStartOfDay(date: date))
    }

    /// Adds a chunk to the appropriate timeline
    private func addChunkToTimeline(_ chunk: StoryChunk, date: Date) {
        let dateKey = dateKey(for: date)

        if var timeline = timelineCache[dateKey] {
            // Add to existing timeline
            timeline.addChunk(chunk)
            timelineCache[dateKey] = timeline
        } else {
            // Create new timeline
            var timeline = DayTimeline.forDate(date)
            timeline.addChunk(chunk)
            timelineCache[dateKey] = timeline
        }
    }

    /// Saves metadata for a specific day
    private func saveMetadata(for date: Date) {
        let dateKey = dateKey(for: date)
        guard let timeline = timelineCache[dateKey] else { return }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted

            let data = try encoder.encode(timeline)
            let metadataURL = metadataURL(for: date)

            // Ensure directory exists
            let dir = metadataURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // Write metadata
            try data.write(to: metadataURL)

            print("💾 Saved metadata: \(metadataURL.lastPathComponent)")
        } catch {
            print("❌ Failed to save metadata: \(error.localizedDescription)")
        }
    }

    /// Loads a timeline from disk for a specific date
    private func loadTimeline(for date: Date) -> DayTimeline? {
        let metadataURL = metadataURL(for: date)

        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let timeline = try decoder.decode(DayTimeline.self, from: data)
            let dateKey = dateKey(for: date)
            timelineCache[dateKey] = timeline

            print("📖 Loaded timeline for \(dateKey): \(timeline.chunkCount) chunks")
            return timeline
        } catch {
            print("❌ Failed to load timeline: \(error.localizedDescription)")
            return nil
        }
    }

    /// Loads all existing timelines from disk into cache
    private func loadAllTimelinesFromDisk() {
        do {
            let fileManager = FileManager.default

            guard fileManager.fileExists(atPath: timelinesDirectory.path) else {
                print("📁 No existing timelines found")
                return
            }

            let dayDirectories = try fileManager.contentsOfDirectory(
                at: timelinesDirectory,
                includingPropertiesForKeys: nil
            )

            var loadedCount = 0
            for dayDir in dayDirectories {
                // Parse date from directory name
                guard let date = dateFormatter.date(from: dayDir.lastPathComponent) else {
                    continue
                }

                // Load timeline
                if loadTimeline(for: date) != nil {
                    loadedCount += 1
                }
            }

            print("✅ Loaded \(loadedCount) timelines from disk")
        } catch {
            print("❌ Failed to load timelines from disk: \(error.localizedDescription)")
        }
    }

    // MARK: - Debug Helpers

    /// Prints storage statistics
    func printStorageStats() {
        print("\n📊 Storage Statistics")
        print("━━━━━━━━━━━━━━━━━━━━")
        print("Total timelines: \(timelineCache.count)")
        print("Total chunks: \(timelineCache.values.reduce(0) { $0 + $1.chunkCount })")

        let totalDuration = timelineCache.values.reduce(0.0) { $0 + $1.totalDuration }
        print("Total duration: \(String(format: "%.1fs", totalDuration))")

        if let storageSize = calculateStorageSize() {
            print("Storage used: \(VideoProcessor.formatFileSize(storageSize))")
        }

        print("━━━━━━━━━━━━━━━━━━━━\n")
    }

    /// Calculates total storage used
    private func calculateStorageSize() -> Int64? {
        do {
            let fileManager = FileManager.default
            var totalSize: Int64 = 0

            let dayDirectories = try fileManager.contentsOfDirectory(
                at: timelinesDirectory,
                includingPropertiesForKeys: [.fileSizeKey]
            )

            for dayDir in dayDirectories {
                let chunkDir = dayDir.appendingPathComponent("chunks")
                if fileManager.fileExists(atPath: chunkDir.path) {
                    let files = try fileManager.contentsOfDirectory(at: chunkDir, includingPropertiesForKeys: [.fileSizeKey])
                    for file in files {
                        let attributes = try fileManager.attributesOfItem(atPath: file.path)
                        if let size = attributes[.size] as? Int64 {
                            totalSize += size
                        }
                    }
                }
            }

            return totalSize
        } catch {
            return nil
        }
    }
}
