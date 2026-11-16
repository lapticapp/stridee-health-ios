import Foundation

/// The windows a long HealthKit read is cut into.
///
/// A first sync can cover a year. Read in one go, that holds every sample of
/// the year in memory at once and only counts as done at the very end: an app
/// the system kills on the way starts the whole year over at the next launch,
/// and keeps starting over. Read window by window, each window is small, and
/// the progress saved after it is kept.
///
/// Edges fall on local midnights, so a day's totals and its samples always come
/// from the same window. The last window ends at `end` itself.
enum SyncWindows {
    struct Window: Equatable {
        let start: Date
        let end: Date
    }

    /// `[start, end]` cut into windows of at most `days` whole days, oldest first.
    static func cut(from start: Date, to end: Date, days: Int, calendar: Calendar) -> [Window] {
        guard start < end else { return [] }
        let days = max(1, days)
        var windows: [Window] = []
        var from = start
        while from < end {
            let dayStart = calendar.startOfDay(for: from)
            guard let to = calendar.date(byAdding: .day, value: days, to: dayStart), to < end else {
                windows.append(Window(start: from, end: end))
                break
            }
            windows.append(Window(start: from, end: to))
            from = to
        }
        return windows
    }
}

extension Array {
    /// Consecutive slices of at most `size` elements, in order.
    func chunked(by size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
