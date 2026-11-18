import XCTest
@testable import StrideeHealth

final class SyncStateTests: XCTestCase {
    private func makeState() -> SyncState {
        let suite = "SyncStateTests.\(UUID().uuidString)"
        return SyncState(defaults: UserDefaults(suiteName: suite)!)
    }

    func testLastDataFoundRoundTripsPerType() {
        let state = makeState()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        state.lastDataFound = [.workouts: date]

        XCTAssertEqual(state.lastDataFound[.workouts], date)
        XCTAssertNil(state.lastDataFound[.wellness])
    }

    func testWellnessCollectedThroughRoundTrips() {
        let state = makeState()
        XCTAssertNil(state.wellnessCollectedThrough)

        let edge = Date(timeIntervalSince1970: 1_790_000_000)
        state.wellnessCollectedThrough = edge

        XCTAssertEqual(state.wellnessCollectedThrough, edge)
    }

    func testResetForgetsEverythingAboutTheConnection() {
        let state = makeState()
        state.isConnected = true
        state.lastSyncDate = Date()
        state.wellnessCollectedThrough = Date()
        state.wellnessHistoryStart = Date()
        state.wellnessHistoryReachedBack = Date()
        state.workoutsSince = Date()
        state.lastDataFound = [.wellness: Date()]

        state.reset()

        XCTAssertFalse(state.isConnected)
        XCTAssertNil(state.lastSyncDate)
        XCTAssertNil(state.wellnessCollectedThrough)
        XCTAssertNil(state.wellnessHistoryStart)
        XCTAssertNil(state.wellnessHistoryReachedBack)
        XCTAssertNil(state.workoutsSince, "a reconnect reads workouts from its own moment, not the first one's")
        XCTAssertTrue(state.lastDataFound.isEmpty)
    }

    func testIgnoringOneMoreAppKeepsTheWellnessAlreadyCollected() {
        let state = makeState()
        let through = Date(timeIntervalSince1970: 1_790_000_000)
        state.wellnessCollectedThrough = through
        state.ignoreWellness(writtenBy: ["com.whoop.iphone"])
        state.ignoreWellness(writtenBy: ["com.whoop.iphone", "com.garmin.connect.mobile"])

        XCTAssertEqual(state.ignoredWellnessSources, ["com.whoop.iphone", "com.garmin.connect.mobile"])
        XCTAssertEqual(state.wellnessCollectedThrough, through)
    }

    func testAnAppNoLongerIgnoredHasTheWellnessHistoryReadAgain() {
        let state = makeState()
        state.ignoreWellness(writtenBy: ["com.whoop.iphone", "com.garmin.connect.mobile"])
        state.wellnessCollectedThrough = Date()
        state.wellnessHistoryStart = Date()
        state.wellnessHistoryReachedBack = Date()

        state.ignoreWellness(writtenBy: ["com.garmin.connect.mobile"])

        XCTAssertEqual(state.ignoredWellnessSources, ["com.garmin.connect.mobile"])
        XCTAssertNil(state.wellnessCollectedThrough, "the days WHOOP covered are read from Apple Health again")
        XCTAssertNil(state.wellnessHistoryStart)
        XCTAssertNil(state.wellnessHistoryReachedBack)
    }

    func testTheIgnoredAppsOutliveADisconnect() {
        let state = makeState()
        state.ignoreWellness(writtenBy: ["com.whoop.iphone"])
        state.reset()
        XCTAssertEqual(state.ignoredWellnessSources, ["com.whoop.iphone"])
    }
}
