import XCTest
@testable import StrideeHealth

final class UploadQueueTests: XCTestCase {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeQueue() -> UploadQueue {
        UploadQueue(directory: makeDirectory())
    }

    func testOldestFirstAndKindRoundTrip() async {
        let queue = makeQueue()
        let first = await queue.enqueue(Data("a".utf8), kind: .workout, key: "A-1")
        XCTAssertTrue(first)
        try? await Task.sleep(nanoseconds: 2_000_000)
        let second = await queue.enqueue(Data("b".utf8), kind: .wellness, key: "B-2")
        XCTAssertTrue(second)

        let items = await queue.items()
        XCTAssertEqual(items.map(\.kind), [.workout, .wellness])
        let body = await queue.body(of: items[0])
        XCTAssertEqual(body, Data("a".utf8))
    }

    func testSameWorkoutIsQueuedOnce() async {
        let queue = makeQueue()
        let first = await queue.enqueue(Data("x".utf8), kind: .workout, key: "SAME-UUID")
        let again = await queue.enqueue(Data("x".utf8), kind: .workout, key: "SAME-UUID")
        XCTAssertTrue(first)
        XCTAssertFalse(again)
        let count = await queue.count
        XCTAssertEqual(count, 1)
    }

    func testRemove() async {
        let queue = makeQueue()
        await queue.enqueue(Data("x".utf8), kind: .workout, key: "K")
        await queue.remove(queue.items()[0])
        let count = await queue.count
        XCTAssertEqual(count, 0)
    }

    func testAQueueOpenedAfterAKilledAppFindsWhatTheDiskHolds() async {
        let directory = makeDirectory()
        let before = UploadQueue(directory: directory)
        await before.enqueue(Data("a".utf8), kind: .workout, key: "0D3C-WORKOUT")
        try? await Task.sleep(nanoseconds: 2_000_000)
        await before.enqueue(Data("b".utf8), kind: .wellness, key: "WELLNESS-1")
        try? await Task.sleep(nanoseconds: 2_000_000)
        await before.enqueue(Data("c".utf8), kind: .workout, key: "SENT")
        await before.remove(before.items()[2])

        let after = UploadQueue(directory: directory)
        let items = await after.items()
        XCTAssertEqual(items.map(\.key), ["0D3C-WORKOUT", "WELLNESS-1"])
        XCTAssertEqual(items.map(\.kind), [.workout, .wellness])
        let requeued = await after.enqueue(Data("a".utf8), kind: .workout, key: "0D3C-WORKOUT")
        XCTAssertFalse(requeued)
    }

    func testRemoveAllEmptiesTheDiskToo() async {
        let directory = makeDirectory()
        let queue = UploadQueue(directory: directory)
        await queue.enqueue(Data("a".utf8), kind: .workout, key: "A")
        await queue.enqueue(Data("b".utf8), kind: .wellness, key: "B")
        await queue.removeAll()

        let reopened = await UploadQueue(directory: directory).count
        XCTAssertEqual(reopened, 0)
        let requeued = await queue.enqueue(Data("a".utf8), kind: .workout, key: "A")
        XCTAssertTrue(requeued)
    }

    func testAThousandQueuedUploadsAreListedOnceAndDrainedOffTheMainThread() async {
        let directory = makeDirectory()
        let filling = UploadQueue(directory: directory)
        for number in 0..<1_000 {
            await filling.enqueue(Data(repeating: 7, count: 4_096), kind: .workout, key: "WORKOUT-\(number)")
        }

        let queue = UploadQueue(directory: directory)
        let started = Date()
        let items = await queue.items()
        for item in items {
            _ = await queue.body(of: item)
            await queue.remove(item)
            _ = await queue.count
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(items.count, 1_000)
        let left = await queue.count
        XCTAssertEqual(left, 0)
        XCTAssertLessThan(elapsed, 5, "draining a thousand uploads took \(elapsed)s")
    }

    func testAnUploadOfADataTypeNoLongerSyncedIsNotSent() {
        let wellnessOnly = HealthSync.Configuration(
            tokenProvider: { HealthSync.DeviceToken(token: "t", expiresAt: .distantFuture) },
            dataTypes: [.wellness]
        )
        let both = HealthSync.Configuration(
            tokenProvider: { HealthSync.DeviceToken(token: "t", expiresAt: .distantFuture) }
        )

        XCTAssertFalse(wellnessOnly.sends(.workout))
        XCTAssertTrue(wellnessOnly.sends(.wellness))
        XCTAssertTrue(both.sends(.workout))
        XCTAssertTrue(both.sends(.wellness))
    }
}
