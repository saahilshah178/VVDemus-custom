import XCTest
@testable import VVDemus

/// The saved session as a value and as two files — the half of "the queue survives the app
/// going away" that needs no player.
///
/// `SessionRestoreTests` covers what `PlayerService` saves and what it does with what comes
/// back. This covers what happens in between, where the failure is quiet: a position applied
/// to the wrong song, or a file from a newer build read as if it were this one's.
@MainActor
final class SavedSessionTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VVDemusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let savedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func track(_ id: String, duration: Int? = 180) -> Track {
        Track(videoId: id, title: "Track \(id)", artist: "Artist", album: nil, thumbnailUrl: nil,
              durationSeconds: duration)
    }

    private func session(
        _ id: String = "a",
        position: Double = 60,
        duration: Double = 180,
        trackDuration: Int? = 180
    ) -> SavedSession {
        SavedSession(
            savedAt: savedAt,
            currentTrack: track(id, duration: trackDuration),
            position: position,
            duration: duration,
            manualQueue: [track("m1")],
            contextQueue: [track("c2"), track("c1")],
            orderedContextQueue: [track("c1"), track("c2")],
            isShuffling: true,
            queueContextTitle: "A Mix",
            contextSeed: track("seed"),
            currentTrackOrigin: .manual,
            currentTrackOrderedIndex: 3,
            history: [SavedSession.Played(track: track("h1"), origin: .context, orderedIndex: 1)]
        )
    }

    private func mark(_ id: String = "a", position: Double, after seconds: TimeInterval = 10,
                      duration: Double = 180) -> SavedPosition {
        SavedPosition(videoId: id, position: position, duration: duration,
                      savedAt: savedAt.addingTimeInterval(seconds))
    }

    // MARK: - Which position belongs to which session

    func testALaterPositionForTheSameTrackIsWhereItResumes() {
        XCTAssertEqual(session().overlaying(mark(position: 95)).position, 95)
    }

    /// The two files are written separately, so at every track boundary there is a moment
    /// when they describe different songs. Applied anyway, the next song would start partway
    /// through at wherever its predecessor was left.
    func testAPositionForAnotherTrackIsIgnored() {
        XCTAssertEqual(session("a").overlaying(mark("b", position: 95)).position, 60)
    }

    /// The session is rewritten whenever the queue is edited, with the position as it was at
    /// that moment — so a mark from before the edit is the older of the two.
    func testAPositionOlderThanTheSessionIsIgnored() {
        XCTAssertEqual(session().overlaying(mark(position: 20, after: -30)).position, 60)
    }

    func testNoPositionAtAllLeavesTheSessionsOwn() {
        XCTAssertEqual(session().overlaying(nil), session())
    }

    /// The player's measured length is the more precise figure once it has one; a mark
    /// written before it did carries zero, and that must not erase a length already known.
    func testAMarkWithoutALengthKeepsTheSessionsLength() {
        XCTAssertEqual(session(duration: 180).overlaying(mark(position: 95, duration: 0)).duration, 180)
        XCTAssertEqual(session(duration: 180).overlaying(mark(position: 95, duration: 179.6)).duration, 179.6)
    }

    // MARK: - What a saved number is allowed to become

    func testAPositionInsideTheTrackIsKept() {
        XCTAssertEqual(session(position: 179.5).resumePosition, 179.5)
        XCTAssertEqual(session(position: 0).resumePosition, 0)
    }

    func testAPositionAtOrPastTheEndStartsFromTheTop() {
        XCTAssertEqual(session(position: 180).resumePosition, 0)
        XCTAssertEqual(session(position: 9_000).resumePosition, 0)
    }

    func testAPositionThatIsNotANumberOfSecondsStartsFromTheTop() {
        XCTAssertEqual(session(position: -1).resumePosition, 0)
        XCTAssertEqual(session(position: .nan).resumePosition, 0)
        XCTAssertEqual(session(position: .infinity).resumePosition, 0)
    }

    /// With no length known from either source there is nothing to check the position
    /// against, and a plausible one is believed rather than thrown away.
    func testAPositionIsBelievedWhenTheLengthIsUnknown() {
        XCTAssertEqual(session(position: 400, duration: 0, trackDuration: nil).resumePosition, 400)
    }

    func testTheLengthFallsBackToTheTracksOwn() {
        XCTAssertEqual(session(duration: 0, trackDuration: 200).resumeDuration, 200)
        XCTAssertEqual(session(duration: .nan, trackDuration: 200).resumeDuration, 200)
        XCTAssertEqual(session(duration: 179.6, trackDuration: 200).resumeDuration, 179.6)
        XCTAssertEqual(session(duration: 0, trackDuration: nil).resumeDuration, 0)
    }

    // MARK: - How often the position is worth writing

    func testTheFirstPositionForATrackIsAlwaysWritten() {
        XCTAssertTrue(SavedPosition.isWorthWriting(0, videoId: "a", lastWritten: nil))
        XCTAssertTrue(SavedPosition.isWorthWriting(0, videoId: "b", lastWritten: (videoId: "a", position: 0)))
    }

    func testOrdinaryPlaybackIsWrittenOnceItHasMovedFarEnough() {
        let last = (videoId: "a", position: 30.0)
        XCTAssertFalse(SavedPosition.isWorthWriting(30.5, videoId: "a", lastWritten: last))
        XCTAssertFalse(SavedPosition.isWorthWriting(34.5, videoId: "a", lastWritten: last))
        XCTAssertTrue(SavedPosition.isWorthWriting(35, videoId: "a", lastWritten: last))
    }

    /// Distance, not direction: scrubbing back to the start is as much a change as playing on.
    func testAJumpBackwardsIsWrittenToo() {
        XCTAssertTrue(SavedPosition.isWorthWriting(0, videoId: "a", lastWritten: (videoId: "a", position: 120)))
    }

    // MARK: - On disk

    func testASessionSurvivesTheDiskWhole() {
        let archive = SessionArchive(directory: directory)

        archive.write(session())

        XCTAssertEqual(archive.read(), session())
    }

    func testThePositionFileIsLaidOverTheSessionWhenRead() {
        let archive = SessionArchive(directory: directory)
        archive.write(session())

        archive.write(mark(position: 95))

        XCTAssertEqual(archive.read()?.position, 95)
        XCTAssertEqual(archive.read()?.currentTrack.videoId, "a")
    }

    func testNothingSavedReadsAsNothing() {
        XCTAssertNil(SessionArchive(directory: directory).read())
    }

    /// A position with no session beside it is not half a session.
    func testAPositionAloneReadsAsNothing() {
        let archive = SessionArchive(directory: directory)

        archive.write(mark(position: 95))

        XCTAssertNil(archive.read())
    }

    func testAnUnreadableSessionReadsAsNothingRatherThanFailing() throws {
        let archive = SessionArchive(directory: directory)
        try Data("{ not json".utf8).write(to: archive.sessionURL)

        XCTAssertNil(archive.read())
    }

    /// An unreadable position costs the last few seconds, not the queue.
    func testAnUnreadablePositionFallsBackToTheSessionsOwn() throws {
        let archive = SessionArchive(directory: directory)
        archive.write(session())
        try Data("{ not json".utf8).write(to: archive.positionURL)

        XCTAssertEqual(archive.read(), session())
    }

    /// Going back to an older build after a newer one has written a shape it does not know.
    /// It starts empty rather than guessing at fields that may mean something else now.
    func testASessionFromANewerBuildReadsAsNothing() {
        let archive = SessionArchive(directory: directory)
        var newer = session()
        newer.version = SavedSession.currentVersion + 1

        archive.write(newer)

        XCTAssertNil(archive.read())
    }

    func testRemovingLeavesNeitherFileBehind() {
        let archive = SessionArchive(directory: directory)
        archive.write(session())
        archive.write(mark(position: 95))

        archive.remove()

        XCTAssertNil(archive.read())
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.sessionURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.positionURL.path))
    }

    // MARK: - The store in front of the files

    /// Writes are handed to a queue and return at once, so the thing to pin down is that they
    /// still land in the order they were asked for: a read straight after a write sees it,
    /// and a clear is not overtaken by the save before it.
    func testTheStoreKeepsWritesInTheOrderTheyWereAskedFor() {
        let store = PlaybackSessionFileStore(directory: directory)

        store.save(session())
        store.savePosition(mark(position: 95))
        XCTAssertEqual(store.load()?.position, 95)

        store.save(session("b", position: 5))
        XCTAssertEqual(store.load()?.currentTrack.videoId, "b")
        XCTAssertEqual(store.load()?.position, 5, "The previous track's position was applied to the new one")

        store.save(session("c"))
        store.clear()
        XCTAssertNil(store.load())
    }

    /// What a relaunch actually is: a second store, opened on the directory the first one
    /// wrote to, after the first has been told the process is going away.
    func testWhatWasFlushedIsThereForTheNextLaunch() {
        let firstLaunch = PlaybackSessionFileStore(directory: directory)
        firstLaunch.save(session())
        firstLaunch.savePosition(mark(position: 95))
        firstLaunch.flush()

        let nextLaunch = PlaybackSessionFileStore(directory: directory)

        XCTAssertEqual(nextLaunch.load()?.currentTrack.videoId, "a")
        XCTAssertEqual(nextLaunch.load()?.position, 95)
        XCTAssertEqual(nextLaunch.load()?.manualQueue.map(\.videoId), ["m1"])
    }

    /// The directory does not exist on a first launch, and the first save must not be the
    /// thing that discovers that.
    func testTheStoreCreatesItsDirectory() {
        let nested = directory.appendingPathComponent("not/there/yet", isDirectory: true)
        let store = PlaybackSessionFileStore(directory: nested)

        store.save(session())

        XCTAssertEqual(store.load(), session())
    }
}
