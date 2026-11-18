import Foundation

/// Uploads waiting to go out, one file each, on disk.
///
/// The reason the HealthKit anchor can be advanced the moment a workout is read
/// rather than the moment it is uploaded: once it is in this queue it survives
/// the app being killed, the network being down and the developer's token
/// endpoint failing. The app this replaces kept nothing between runs and
/// re-sent its whole batch after any single failure.
///
/// Files are named `<milliseconds>-<kind>-<key>.json`, so a directory listing
/// sorted by name is oldest first. Protected until first unlock: background
/// delivery wakes the app while the phone is locked, and the queue has to be
/// readable then.
///
/// An actor, so no file is ever listed, read or written on the main thread. The
/// directory is listed once, on first use, and the queue then keeps its own
/// index: it is the only writer, so the index stays what the disk holds. A file
/// is written before it joins the index and deleted before it leaves it, so an
/// app killed in between finds at worst a file the index never had, which the
/// next launch's listing picks up.
actor UploadQueue {
    enum Kind: String, Sendable {
        case workout
        case wellness
    }

    struct Item: Sendable, Equatable {
        let url: URL
        let kind: Kind
        let key: String
    }

    let directory: URL

    private var index: [Item]?
    private var keys: Set<String> = []

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StrideeHealth", isDirectory: true)
            .appendingPathComponent("Queue", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    /// Add one upload. `key` makes it unique: a workout already queued under
    /// the same key is not queued twice.
    @discardableResult
    func enqueue(_ body: Data, kind: Kind, key: String) -> Bool {
        loadIfNeeded()
        guard !keys.contains(key) else { return false }
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        // Zero-padded so a lexical sort is a chronological one.
        let name = String(format: "%015llu", millis) + "-\(kind.rawValue)-\(key).json"
        let url = directory.appendingPathComponent(name)
        do {
            try body.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return false
        }
        index?.append(Item(url: url, kind: kind, key: key))
        keys.insert(key)
        return true
    }

    /// Everything queued, oldest first.
    func items() -> [Item] {
        loaded()
    }

    var count: Int { loaded().count }

    func body(of item: Item) -> Data? {
        try? Data(contentsOf: item.url)
    }

    func remove(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
        loadIfNeeded()
        if let position = index?.firstIndex(of: item) { index?.remove(at: position) }
        keys.remove(item.key)
    }

    func removeAll() {
        for item in loaded() {
            try? FileManager.default.removeItem(at: item.url)
        }
        index = []
        keys = []
    }

    private func loaded() -> [Item] {
        loadIfNeeded()
        return index ?? []
    }

    private func loadIfNeeded() {
        guard index == nil else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let listed = names
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .compactMap { name -> Item? in
                let parts = name.dropLast(".json".count).split(separator: "-", maxSplits: 2)
                guard parts.count == 3, let kind = Kind(rawValue: String(parts[1])) else { return nil }
                return Item(url: directory.appendingPathComponent(name), kind: kind, key: String(parts[2]))
            }
        index = listed
        keys = Set(listed.map(\.key))
    }
}
