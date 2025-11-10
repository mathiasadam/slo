import Foundation

/// Represents a timeline for a single day, containing all story chunks posted on that day
struct DayTimeline: Identifiable, Codable, Equatable {
    /// Unique identifier for the timeline
    let id: UUID

    /// Date normalized to 00:00:00 of the day
    let date: Date

    /// Array of story chunks posted on this day, sorted by timestamp
    var chunks: [StoryChunk]

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        date: Date,
        chunks: [StoryChunk] = []
    ) {
        self.id = id
        // Always normalize the date to start of day
        self.date = normalizeToStartOfDay(date: date)
        // Keep chunks sorted by timestamp
        self.chunks = chunks.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Computed Properties

    /// Total duration of all chunks in the timeline (in seconds)
    var totalDuration: TimeInterval {
        chunks.reduce(0) { $0 + $1.duration }
    }

    /// Number of story chunks in this timeline
    var chunkCount: Int {
        chunks.count
    }

    /// Checks if this timeline is for today
    var isToday: Bool {
        isSameDay(date, Date())
    }

    /// Checks if this timeline is for yesterday
    var isYesterday: Bool {
        again2.isYesterday(date)
    }

    /// Returns a human-readable string for the timeline's date
    var formattedDate: String {
        formattedDayString(for: date)
    }

    /// Returns a formatted total duration string (e.g., "5m 32s")
    var formattedTotalDuration: String {
        let minutes = Int(totalDuration) / 60
        let seconds = Int(totalDuration) % 60

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    /// Returns the first chunk in the timeline (useful for preview)
    var firstChunk: StoryChunk? {
        chunks.first
    }

    /// Returns the last chunk in the timeline
    var lastChunk: StoryChunk? {
        chunks.last
    }

    /// Checks if the timeline is empty
    var isEmpty: Bool {
        chunks.isEmpty
    }

    // MARK: - Mutating Methods

    /// Adds a new story chunk to the timeline
    /// - Parameter chunk: The chunk to add
    mutating func addChunk(_ chunk: StoryChunk) {
        chunks.append(chunk)
        // Re-sort to maintain chronological order
        chunks.sort { $0.timestamp < $1.timestamp }
    }

    /// Removes a story chunk from the timeline
    /// - Parameter chunkId: The ID of the chunk to remove
    mutating func removeChunk(withId chunkId: UUID) {
        chunks.removeAll { $0.id == chunkId }
    }

    /// Removes a story chunk at a specific index
    /// - Parameter index: The index of the chunk to remove
    mutating func removeChunk(at index: Int) {
        guard index >= 0 && index < chunks.count else { return }
        chunks.remove(at: index)
    }

    /// Removes all chunks from the timeline
    mutating func removeAllChunks() {
        chunks.removeAll()
    }

    // MARK: - Static Factory Methods

    /// Creates a DayTimeline for today
    static func today() -> DayTimeline {
        DayTimeline(date: Date())
    }

    /// Creates a DayTimeline for a specific date
    /// - Parameter date: The date for the timeline
    static func forDate(_ date: Date) -> DayTimeline {
        DayTimeline(date: date)
    }

    // MARK: - Equatable Conformance

    static func == (lhs: DayTimeline, rhs: DayTimeline) -> Bool {
        lhs.id == rhs.id &&
        isSameDay(lhs.date, rhs.date) &&
        lhs.chunks == rhs.chunks
    }
}

// MARK: - DayTimeline Array Extensions

extension Array where Element == DayTimeline {
    /// Sorts timelines by date, most recent first
    func sortedByDateDescending() -> [DayTimeline] {
        sorted { $0.date > $1.date }
    }

    /// Sorts timelines by date, oldest first
    func sortedByDateAscending() -> [DayTimeline] {
        sorted { $0.date < $1.date }
    }

    /// Finds a timeline for a specific date
    /// - Parameter date: The date to search for
    /// - Returns: The timeline for that date, if it exists
    func timeline(forDate date: Date) -> DayTimeline? {
        let normalizedDate = normalizeToStartOfDay(date: date)
        return first { isSameDay($0.date, normalizedDate) }
    }

    /// Filters to only include timelines with chunks
    var nonEmpty: [DayTimeline] {
        filter { !$0.isEmpty }
    }

    /// Returns the total number of chunks across all timelines
    var totalChunkCount: Int {
        reduce(0) { $0 + $1.chunkCount }
    }

    /// Returns the total duration across all timelines
    var totalDuration: TimeInterval {
        reduce(0) { $0 + $1.totalDuration }
    }
}
