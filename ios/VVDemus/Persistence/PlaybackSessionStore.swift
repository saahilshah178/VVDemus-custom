import Foundation

/// The saved session's two files, and nothing about when they are written.
///
/// Files rather than `UserDefaults`, which is where most of the stores here keep their state.
/// A queue can be a whole playlist — twice over, since the shuffled and unshuffled orders are
/// both kept — and the position is rewritten every few seconds for as long as music plays.
/// Defaults are one property list, rewritten whole whenever any key in it changes, so either
/// of those would have meant rewriting every liked song and every playlist along with it.
///
/// A plain value with no actor and no queue of its own so the rules that matter — what a
/// half-written or unreadable file turns into, which position belongs to which session — can
/// be exercised against a temporary directory. `PlaybackSessionFileStore` is what decides
/// which thread any of this runs on.
struct SessionArchive {
    let sessionURL: URL
    let positionURL: URL

    init(directory: URL) {
        sessionURL = directory.appendingPathComponent("session.json")
        positionURL = directory.appendingPathComponent("position.json")
    }

    /// What is on disk, or nil when there is nothing there that can be come back to.
    ///
    /// Unreadable is treated exactly like absent, and deliberately not preserved the way
    /// `DefaultsSnapshot` preserves a library blob it cannot decode. That exists because
    /// liked songs and playlists cannot be had again; a queue is rebuilt by pressing play.
    func read() -> SavedSession? {
        guard let session = decode(SavedSession.self, at: sessionURL),
              // Written by a build after this one, in a shape this one does not know.
              session.version == SavedSession.currentVersion else { return nil }
        return session.overlaying(decode(SavedPosition.self, at: positionURL))
    }

    func write(_ session: SavedSession) {
        encode(session, to: sessionURL)
    }

    func write(_ position: SavedPosition) {
        encode(position, to: positionURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: sessionURL)
        try? FileManager.default.removeItem(at: positionURL)
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// `.atomic`, so being ended halfway through a write leaves the previous file rather than
    /// the first half of the next one. Surviving the app being ended is the entire job.
    private func encode<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[PlaybackSession] could not write %@ — %@", url.lastPathComponent, error.localizedDescription)
        }
    }
}

/// The saved session, on disk.
///
/// Writes are handed to a serial queue and return at once: `PlayerService` asks for them from
/// the main actor, in the middle of track changes and from the periodic tick, and neither is
/// a place to wait on a disk. One queue, so writes land in the order they were asked for and
/// a `clear()` cannot be overtaken by the save before it.
@MainActor
final class PlaybackSessionFileStore: PlaybackSessionPersisting {
    static let shared = PlaybackSessionFileStore(directory: defaultDirectory)

    /// What `PlayerService.shared` keeps its session in: the real store, unless this process
    /// is the app standing in as host for its own unit tests.
    ///
    /// `VVDemusTests` is a hosted bundle — the suite is loaded into this app, launched for
    /// real, with the same container — and some of it drives `PlayerService.shared` through
    /// the control server. With the real store those tests would start from whatever that
    /// simulator's app was last playing (and one of them asserts a position of zero), and
    /// would leave their fixtures behind as the session the app opens with next time.
    static var forRunningApp: PlaybackSessionPersisting {
        isHostingUnitTests() ? NoSessionPersistence.shared : shared
    }

    /// Xcode puts these in the environment of an app it launches to host a test bundle. Any
    /// one is enough; which of them is set has varied between Xcode versions.
    nonisolated static func isHostingUnitTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
    }

    private let archive: SessionArchive
    private let queue = DispatchQueue(label: "vvdemus.playback-session", qos: .utility)

    /// In Application Support, like `ListeningStatsStore`'s log and the downloads: this is
    /// state, not a cache, and the Caches directory is the one the system empties when the
    /// disk fills up — which would be a phone forgetting your queue because you took a video.
    ///
    /// Under the bundle id, unlike those two. On a phone that changes nothing, since the
    /// container is this app's alone. The Mac app is not sandboxed, so Application Support
    /// there is the one every app shares — and two builds under different ids would
    /// otherwise each open holding whatever the other had last played, against ownership
    /// records (which are in defaults, and so already per-id) that say otherwise.
    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "VVDemus", isDirectory: true)
            .appendingPathComponent("PlaybackSession", isDirectory: true)
    }

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        archive = SessionArchive(directory: directory)
    }

    /// Through the queue rather than around it, so a read can never see the files as they were
    /// before a write that has already been asked for.
    func load() -> SavedSession? {
        let archive = archive
        return queue.sync { archive.read() }
    }

    func save(_ session: SavedSession) {
        let archive = archive
        queue.async { archive.write(session) }
    }

    func savePosition(_ position: SavedPosition) {
        let archive = archive
        queue.async { archive.write(position) }
    }

    func clear() {
        let archive = archive
        queue.async { archive.remove() }
    }

    func flush() {
        queue.sync {}
    }
}
