import XCTest
@testable import StrideeHealth

final class SyncWindowsTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testAShortRangeIsOneWindowFromStartToEnd() {
        let start = date("2026-11-14T09:30:00+01:00")
        let end = date("2026-11-16T10:39:00+01:00")

        let windows = SyncWindows.cut(from: start, to: end, days: 30, calendar: paris)

        XCTAssertEqual(windows, [.init(start: start, end: end)])
    }

    func testAYearIsCutAtLocalMidnightsAndEndsAtEnd() {
        let calendar = paris
        let end = date("2026-11-16T10:39:00+01:00")
        let start = calendar.date(byAdding: .day, value: -365, to: end)!

        let windows = SyncWindows.cut(from: start, to: end, days: 30, calendar: calendar)

        XCTAssertEqual(windows.count, 13)
        XCTAssertEqual(windows.first?.start, start)
        XCTAssertEqual(windows.last?.end, end)
        for (earlier, later) in zip(windows, windows.dropFirst()) {
            XCTAssertEqual(earlier.end, later.start)
            XCTAssertEqual(calendar.startOfDay(for: earlier.end), earlier.end, "an edge is a local midnight")
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: earlier.start), to: earlier.end).day
            XCTAssertEqual(days, 30)
        }
    }

    func testEdgesStayOnMidnightAcrossTheEndOfSummerTime() {
        let calendar = paris
        let start = date("2026-10-10T12:00:00+02:00")
        let end = date("2026-11-20T12:00:00+01:00")

        let windows = SyncWindows.cut(from: start, to: end, days: 7, calendar: calendar)

        XCTAssertEqual(windows.count, 6)
        for window in windows.dropLast() {
            XCTAssertEqual(calendar.component(.hour, from: window.end), 0)
            XCTAssertEqual(calendar.component(.minute, from: window.end), 0)
        }
        XCTAssertEqual(windows[2].end, date("2026-10-31T00:00:00+01:00"), "the week over the change still ends at midnight")
    }

    func testAnEmptyOrReversedRangeHasNoWindow() {
        let moment = date("2026-11-16T10:39:00+01:00")
        XCTAssertEqual(SyncWindows.cut(from: moment, to: moment, days: 30, calendar: paris), [])
        XCTAssertEqual(SyncWindows.cut(from: moment, to: moment.addingTimeInterval(-60), days: 30, calendar: paris), [])
    }

    func testChunkedKeepsOrderAndFillsAllButTheLast() {
        XCTAssertEqual([1, 2, 3, 4, 5].chunked(by: 2), [[1, 2], [3, 4], [5]])
        XCTAssertEqual([1, 2].chunked(by: 5), [[1, 2]])
        XCTAssertEqual([Int]().chunked(by: 3), [])
    }
}
