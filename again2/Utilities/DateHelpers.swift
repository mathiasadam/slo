import Foundation

// MARK: - Date Helper Functions

/// Normalizes a date to the start of the day (00:00:00)
/// - Parameter date: The date to normalize
/// - Returns: A new date set to 00:00:00 of the same day
func normalizeToStartOfDay(date: Date) -> Date {
    let calendar = Calendar.current
    return calendar.startOfDay(for: date)
}

/// Checks if two dates fall on the same day, ignoring time components
/// - Parameters:
///   - date1: First date to compare
///   - date2: Second date to compare
/// - Returns: `true` if both dates are on the same day, `false` otherwise
func isSameDay(_ date1: Date, _ date2: Date) -> Bool {
    let calendar = Calendar.current
    return calendar.isDate(date1, inSameDayAs: date2)
}

/// Checks if a date is today
/// - Parameter date: The date to check
/// - Returns: `true` if the date is today, `false` otherwise
func isToday(_ date: Date) -> Bool {
    isSameDay(date, Date())
}

/// Checks if a date is yesterday
/// - Parameter date: The date to check
/// - Returns: `true` if the date is yesterday, `false` otherwise
func isYesterday(_ date: Date) -> Bool {
    let calendar = Calendar.current
    guard let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) else {
        return false
    }
    return isSameDay(date, yesterday)
}

/// Returns a formatted date string for display (e.g., "Today", "Yesterday", "Nov 10, 2024")
/// - Parameter date: The date to format
/// - Returns: A human-readable date string
func formattedDayString(for date: Date) -> String {
    if isToday(date) {
        return "Today"
    } else if isYesterday(date) {
        return "Yesterday"
    } else {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

/// Returns the number of days between two dates
/// - Parameters:
///   - startDate: The start date
///   - endDate: The end date
/// - Returns: Number of days between the dates (can be negative if endDate is before startDate)
func daysBetween(startDate: Date, endDate: Date) -> Int {
    let calendar = Calendar.current
    let components = calendar.dateComponents([.day], from: normalizeToStartOfDay(date: startDate), to: normalizeToStartOfDay(date: endDate))
    return components.day ?? 0
}

/// Checks if it's past 00:01 AM (day rollover time)
/// - Parameter date: The date to check
/// - Returns: `true` if the time is 00:01 AM or later on the same day
func isPastDayRollover(_ date: Date = Date()) -> Bool {
    let calendar = Calendar.current
    let components = calendar.dateComponents([.hour, .minute], from: date)

    guard let hour = components.hour, let minute = components.minute else {
        return false
    }

    // Day rollover happens at 00:01 AM
    if hour == 0 && minute >= 1 {
        return true
    }

    // Any time after 00:01 AM
    return hour > 0 || (hour == 0 && minute > 1)
}

/// Returns the date for the current day's rollover (00:01 AM)
/// - Returns: Date set to 00:01 AM of today
func todayRolloverTime() -> Date {
    let calendar = Calendar.current
    let today = normalizeToStartOfDay(date: Date())
    return calendar.date(byAdding: .minute, value: 1, to: today) ?? today
}

/// Returns the date for the next day's rollover (00:01 AM tomorrow)
/// - Returns: Date set to 00:01 AM of tomorrow
func nextDayRolloverTime() -> Date {
    let calendar = Calendar.current
    let today = normalizeToStartOfDay(date: Date())
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
        return today
    }
    return calendar.date(byAdding: .minute, value: 1, to: tomorrow) ?? tomorrow
}
