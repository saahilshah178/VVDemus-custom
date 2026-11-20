import XCTest
@testable import VVDemus

/// The session surviving the app going away.
///
/// Nothing used to be written down, so closing the app ended the queue — and so did leaving a
/// phone alone for an evening, because iOS ends an app that sits paused in the background and
/// the next launch is a cold one. Both looked the same from the outside: you came back to a
/// blank player.
///
/// A relaunch here is two harnesses sharing one `FakeSessionStore`, which is the only thing
/// two runs of the app have in common.
@MainActor
final class SessionRestoreTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    override func tearDown() async throws {
        PlayerService.sessionSaveDelay = 0.5
    }

    /// The app going away *with* warning — backgrounded on a phone, quit on a Mac — and being
    /// opened again.
    private func relaunch() -> PlayerHarness {
        harness.player.saveSessionNow()
        return PlayerHarness(sessionStore: harness.sessionStore)
    }

    /// The app being ended with no warning at all, so only what had already been written
    /// survives.
    private func relaunchAfterBeingKilled() -> PlayerHarness {
        PlayerHarness(sessionStore: harness.sessionStore)
    }

    private func ids(_ tracks: [Track]) -> [String] { tracks.map(\.videoId) }

    // MARK: - Coming back

    func testTheSessionComesBackAfterTheAppIsClosedAndReopened() async {
        let list = Fixtures.tracks(["a", "b", "c", "d"])
        harness.player.play(track: list[1], context: list, contextTitle: "Morning Mix")
        await harness.settle { !self.harness.player.isLoading }
        harness.player.addToQueue(Fixtures.track("x"))
        harness.engine.tick(to: 42)
        harness.player.togglePlayPause() // pause

        let relaunched = relaunch()

        XCTAssertEqual(relaunched.player.currentTrack?.videoId, "b")
        XCTAssertEqual(ids(relaunched.player.manualQueue), ["x"])
        XCTAssertEqual(ids(relaunched.player.contextQueue), ["c", "d"])
        XCTAssertEqual(relaunched.player.queueContextTitle, "Morning Mix")
        XCTAssertEqual(relaunched.player.progress, 42, accuracy: 0.001)
        XCTAssertEqual(relaunched.player.duration, 180, accuracy: 0.001)
    }

    /// It was playing when the app went away, and it still comes back paused. A device that
    /// starts making noise because it was opened is worse than the blank player this replaces.
    func testItComesBackPausedEvenIfItWasPlaying() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 30)
        XCTAssertTrue(harness.player.isPlaying, "Precondition: the app goes away mid-song")

        let relaunched = relaunch()
        await relaunched.drain()

        XCTAssertEqual(relaunched.player.currentTrack?.videoId, "a")
        XCTAssertFalse(relaunched.player.isPlaying)
        XCTAssertFalse(relaunched.player.isLoading)
        XCTAssertFalse(relaunched.engine.isEnginePlaying)
    }

    /// Opening the app is not a request to do anything. No stream is resolved — so no network
    /// at launch, and nothing to fail with no signal — the audio route is not taken from
    /// whatever else is playing, and the track is not filed as played again.
    func testComingBackTouchesNothingUntilPlayIsPressed() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 30)
        harness.player.saveSessionNow()
        let sessionWrites = harness.sessionStore.sessionWrites
        let positionWrites = harness.sessionStore.positionWrites.count
        // So that a save wrongly scheduled by the restore would land inside the wait below
        // instead of half a second after this test has finished looking.
        PlayerService.sessionSaveDelay = 0

        let relaunched = relaunchAfterBeingKilled()
        await relaunched.drain()

        XCTAssertEqual(relaunched.engine.events, [])
        XCTAssertEqual(relaunched.session.activations, [])
        XCTAssertTrue(relaunched.streams.resolveCount.isEmpty)
        XCTAssertTrue(relaunched.sideEffects.plays.isEmpty)
        XCTAssertTrue(relaunched.sideEffects.listening.isEmpty)
        XCTAssertNil(relaunched.player.errorMessage)
        // Reading the session back is not an edit to it.
        XCTAssertEqual(relaunched.sessionStore.sessionWrites, sessionWrites)
        XCTAssertEqual(relaunched.sessionStore.positionWrites.count, positionWrites)
        XCTAssertEqual(relaunched.sessionStore.clears, 0)
    }

    func testPlayPicksTheTrackUpWhereItWasLeft() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 180))
        harness.engine.tick(to: 42)
        let relaunched = relaunch()

        relaunched.player.togglePlayPause()
        await relaunched.settle { relaunched.engine.attachCount == 1 && !relaunched.player.isLoading }

        XCTAssertTrue(relaunched.player.isPlaying)
        XCTAssertTrue(relaunched.engine.didPlayAfterLastAttach)
        XCTAssertEqual(
            relaunched.engine.currentTimeSeconds, 42, accuracy: 0.001,
            "The player itself started at the top; only the scrubber remembered"
        )
        // What the user sees: the next tick reports the engine's real position.
        relaunched.engine.tick(to: relaunched.engine.currentTimeSeconds)
        XCTAssertEqual(relaunched.player.progress, 42, accuracy: 0.001)
    }

    /// A downloaded track is attached straight from disk, before the load returns — a
    /// different path from a streamed one, and the one that used to start from the top
    /// whatever position it was handed.
    func testADownloadedTrackIsPickedUpWhereItWasLeftToo() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 180))
        harness.engine.tick(to: 42)
        let relaunched = relaunch()
        let file = URL(fileURLWithPath: "/downloads/a.m4a")
        relaunched.downloads.localFiles["a"] = file

        relaunched.player.togglePlayPause()

        XCTAssertEqual(relaunched.engine.events, [.pause, .replaceItem(file), .seek(42), .play])
        XCTAssertEqual(relaunched.player.progress, 42, accuracy: 0.001)
        XCTAssertTrue(relaunched.streams.resolveCount["a"] == nil, "A download needs no stream")
    }

    /// The lock screen's play button and an AirPods tap arrive as remote commands rather than
    /// through the app's own button, and after a relaunch they are how a phone in a pocket is
    /// most likely to be asked to carry on.
    func testTheLockScreenCanPickTheSessionUpToo() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 20)
        let relaunched = relaunch()

        XCTAssertEqual(relaunched.commands.fire(.play), .success)
        await relaunched.settle { relaunched.engine.attachCount == 1 && !relaunched.player.isLoading }

        XCTAssertTrue(relaunched.player.isPlaying)
        XCTAssertEqual(relaunched.engine.currentTimeSeconds, 20, accuracy: 0.001)
    }

    /// The seconds heard before the app went away were never credited — stats are recorded
    /// when a track is replaced, and it never was. They are credited once, when it finally is.
    func testTheTimeListenedBeforeTheRelaunchIsCreditedOnceWhenTheTrackIsLeft() async {
        let list = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(list[0], context: list)
        harness.engine.tick(to: 40)
        let relaunched = relaunch()

        relaunched.player.togglePlayPause()
        await relaunched.settle { relaunched.engine.attachCount == 1 && !relaunched.player.isLoading }
        XCTAssertTrue(relaunched.sideEffects.listening.isEmpty, "Pressing play is not leaving the track")
        relaunched.engine.tick(to: 100)
        relaunched.player.advance()

        XCTAssertEqual(relaunched.sideEffects.listening.count, 1)
        XCTAssertEqual(relaunched.sideEffects.listening.first?.track.videoId, "a")
        XCTAssertEqual(relaunched.sideEffects.listening.first?.seconds, 100)
    }

    // MARK: - The queue behind it

    func testNextCarriesOnDownTheQueueAfterComingBack() async {
        let list = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(list[0], context: list)
        let relaunched = relaunch()

        relaunched.player.advance()
        await relaunched.settle { relaunched.player.currentTrack?.videoId == "b" && !relaunched.player.isLoading }

        XCTAssertEqual(ids(relaunched.player.contextQueue), ["c"])
        XCTAssertTrue(relaunched.player.isPlaying)
    }

    /// Where "previous" leads is part of the session too, including that the track being left
    /// goes back on the front of the queue it came from.
    func testPreviousStillLeadsBackAfterComingBack() async {
        let list = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(list[0], context: list)
        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" && !self.harness.player.isLoading }
        let relaunched = relaunch()
        XCTAssertTrue(relaunched.player.hasPrevious)

        relaunched.player.previous()
        await relaunched.settle { relaunched.player.currentTrack?.videoId == "a" && !relaunched.player.isLoading }

        XCTAssertEqual(ids(relaunched.player.contextQueue), ["b", "c"])
    }

    /// The unshuffled order is saved beside the shuffled one, for the same reason a handoff
    /// carries both: without it, switching shuffle off after a relaunch has nothing to restore.
    func testSwitchingShuffleOffAfterComingBackRestoresTheRealOrder() async {
        let list = Fixtures.tracks(["a", "b", "c", "d", "e", "f", "g", "h"])
        await harness.startPlaying(list[0], context: list)
        harness.player.toggleShuffle()
        let shuffled = ids(harness.player.contextQueue)
        let relaunched = relaunch()

        XCTAssertTrue(relaunched.player.isShuffling)
        XCTAssertEqual(ids(relaunched.player.contextQueue), shuffled, "The shuffle was reshuffled on the way back")

        relaunched.player.toggleShuffle()

        XCTAssertEqual(ids(relaunched.player.contextQueue), ["b", "c", "d", "e", "f", "g", "h"])
    }

    /// A radio is identified by its seed, and a queue that came back without one is a loose
    /// list of songs with no station behind it.
    func testARadioComesBackAsARadio() async {
        let seed = Fixtures.track("seed")
        let mix = Fixtures.tracks(["seed", "r1", "r2"])
        harness.player.play(track: seed, context: mix, contextTitle: "Seed Radio", contextSeed: seed)
        await harness.settle { !self.harness.player.isLoading }

        let relaunched = relaunch()

        XCTAssertEqual(relaunched.player.currentContextSeed, seed)
        XCTAssertEqual(relaunched.player.queueContextTitle, "Seed Radio")
        XCTAssertTrue(relaunched.sideEffects.radioSeeds.isEmpty, "Coming back is not listening to the station again")
    }

    /// The queue ran out and the last track is sitting finished. That comes back as the track
    /// at its top, ready to be played again — not parked on its final second.
    func testAFinishedQueueComesBackAtTheTopOfItsLastTrack() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.radios.failing = ["a"]
        harness.engine.tick(to: 179)
        harness.engine.finishTrack()
        await harness.settle { !self.harness.player.isPlaying && !self.harness.player.isLoading }

        let relaunched = relaunch()
        XCTAssertEqual(relaunched.player.currentTrack?.videoId, "a")
        XCTAssertEqual(relaunched.player.progress, 0, accuracy: 0.001)

        relaunched.player.togglePlayPause()
        await relaunched.settle { relaunched.engine.attachCount == 1 && !relaunched.player.isLoading }

        XCTAssertTrue(relaunched.player.isPlaying)
        XCTAssertEqual(relaunched.engine.currentTimeSeconds, 0, accuracy: 0.001)
    }

    // MARK: - What is written, and when

    /// Nothing has to ask. A change is written a moment after it is made, so an app that is
    /// ended without warning still has the queue as it stood.
    func testAChangeIsWrittenWithoutAnyoneAsking() async {
        PlayerService.sessionSaveDelay = 0
        let list = Fixtures.tracks(["a", "b"])

        harness.player.play(track: list[0], context: list)
        await harness.settle { self.harness.sessionStore.session != nil }

        XCTAssertEqual(harness.sessionStore.session?.currentTrack.videoId, "a")
        XCTAssertEqual(ids(harness.sessionStore.session?.contextQueue ?? []), ["b"])

        harness.player.addToQueue(Fixtures.track("x"))
        await harness.settle { self.harness.sessionStore.session?.manualQueue.isEmpty == false }

        XCTAssertEqual(ids(harness.sessionStore.session?.manualQueue ?? []), ["x"])
    }

    /// Starting a track rewrites the queue, the title, the origin and the track itself — a
    /// dozen assignments. That is one edit, and it is one write.
    func testOneEditIsOneWriteHoweverManyThingsItTouches() async {
        PlayerService.sessionSaveDelay = 0
        let list = Fixtures.tracks(["a", "b", "c"])

        harness.player.play(track: list[0], context: list, contextTitle: "A List")
        await harness.settle { !self.harness.player.isLoading && self.harness.sessionStore.session != nil }
        await harness.drain()

        XCTAssertEqual(harness.sessionStore.sessionWrites, 1)
    }

    /// The whole queue is not rewritten to move one number. While a track plays, only its
    /// position is written, and only every few seconds of it.
    func testPlaybackWritesOnlyThePositionAndOnlyEveryFewSeconds() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.saveSessionNow()
        let sessionWrites = harness.sessionStore.sessionWrites
        let before = harness.sessionStore.positionWrites.count

        for half in 1...9 { harness.engine.tick(to: Double(half) * 0.5) } // 0.5 … 4.5
        XCTAssertEqual(harness.sessionStore.positionWrites.count, before, "Written on every tick")

        harness.engine.tick(to: 5)
        XCTAssertEqual(harness.sessionStore.positionWrites.count, before + 1)
        XCTAssertEqual(harness.sessionStore.positionWrites.last?.position ?? -1, 5, accuracy: 0.001)

        for half in 11...19 { harness.engine.tick(to: Double(half) * 0.5) } // 5.5 … 9.5
        XCTAssertEqual(harness.sessionStore.positionWrites.count, before + 1)
        XCTAssertEqual(harness.sessionStore.sessionWrites, sessionWrites, "The queue was rewritten to move the position")
    }

    func testPausingWritesExactlyWhereItStopped() async {
        await harness.startPlaying(Fixtures.track("a"))
        // With nothing else waiting to be written, so that what the pause writes is the
        // position alone — the case for every pause but the first after a track change.
        harness.player.saveSessionNow()
        harness.engine.tick(to: 5)
        harness.engine.tick(to: 7.5)
        XCTAssertEqual(harness.sessionStore.positionWrites.last?.position ?? -1, 5, accuracy: 0.001,
                       "Precondition: the last mark is behind the playhead")

        harness.player.togglePlayPause()

        XCTAssertEqual(harness.sessionStore.positionWrites.last?.position ?? -1, 7.5, accuracy: 0.001)
        XCTAssertEqual(harness.sessionStore.positionWrites.last?.videoId, "a")
    }

    /// Pause is the last thing a phone in a pocket is told before it may be suspended, and a
    /// suspended app that is then ended never runs its delayed save. A track that changed a
    /// moment before the pause must already be written by the time the pause returns.
    func testPausingWritesAChangeThatWasStillWaiting() async {
        PlayerService.sessionSaveDelay = 60
        let list = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(list[0], context: list)
        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" && !self.harness.player.isLoading }
        harness.engine.tick(to: 3)
        XCTAssertNil(harness.sessionStore.session, "Precondition: the delayed save has not happened yet")

        harness.player.togglePlayPause()

        XCTAssertEqual(harness.sessionStore.session?.currentTrack.videoId, "b")
        XCTAssertEqual(harness.sessionStore.session?.position ?? -1, 3, accuracy: 0.001)
    }

    func testAScrubIsWrittenAtOnce() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 180))
        harness.engine.itemDurationSeconds = 180
        harness.engine.tick(to: 2)

        harness.player.seek(to: 90)

        XCTAssertEqual(harness.sessionStore.positionWrites.last?.position ?? -1, 90, accuracy: 0.001)
    }

    /// A crash, a force quit, a flat battery. The queue is as it last stood and the position
    /// is the last mark, which is at most a few seconds behind.
    func testBeingKilledWithoutWarningLosesOnlyTheLastFewSeconds() async {
        PlayerService.sessionSaveDelay = 0
        let list = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(list[0], context: list)
        await harness.settle { self.harness.sessionStore.session != nil }
        for half in 1...25 { harness.engine.tick(to: Double(half) * 0.5) } // … 12.5

        let relaunched = relaunchAfterBeingKilled()

        XCTAssertEqual(relaunched.player.currentTrack?.videoId, "a")
        XCTAssertEqual(ids(relaunched.player.contextQueue), ["b", "c"])
        XCTAssertEqual(relaunched.player.progress, 10, accuracy: 0.001)
    }

    /// The app is told it is going to the background (or, on a Mac, that it is quitting), and
    /// what it has not yet written has to be on disk before that notification returns — there
    /// may be no later.
    func testTheLastChanceToSaveWritesEverythingBeforeItReturns() async throws {
        let moment = try XCTUnwrap(AppLifecycle.lastChancesToSave.first)
        // Far enough out that the delayed save cannot be what wrote it, however slowly this runs.
        PlayerService.sessionSaveDelay = 60
        let list = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(list[0], context: list)
        harness.engine.tick(to: 3)
        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" && !self.harness.player.isLoading }
        harness.engine.tick(to: 3)
        XCTAssertNotEqual(harness.sessionStore.session?.currentTrack.videoId, "b",
                          "Precondition: the delayed save has not happened yet")

        harness.notifications.post(name: moment, object: nil)

        XCTAssertEqual(harness.sessionStore.session?.currentTrack.videoId, "b")
        XCTAssertEqual(harness.sessionStore.session?.position ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(harness.sessionStore.flushes, 1)
    }

    // MARK: - Letting go

    /// Handing the session to the paired device is the one way a session ends on purpose. If
    /// it stayed on disk, the next launch would bring back a queue that now lives on the
    /// other device — two copies of one session, which is the state the pairing exists to
    /// prevent.
    func testASessionGivenToThePairedDeviceIsForgottenHere() async {
        await harness.startPlaying(Fixtures.track("a"))
        // Paused first, as a handoff leaves it: the sender pauses, then waits for the ack.
        harness.player.togglePlayPause()
        harness.player.saveSessionNow()
        XCTAssertNotNil(harness.sessionStore.session, "Precondition: there is something to forget")
        // The delayed save must not be what forgets it. Ended inside that delay, the app
        // would come back holding a session it had just given away.
        PlayerService.sessionSaveDelay = 60

        harness.player.releaseSession()

        XCTAssertNil(harness.sessionStore.session)
        let relaunched = relaunchAfterBeingKilled()
        XCTAssertNil(relaunched.player.currentTrack)
        XCTAssertTrue(relaunched.player.contextQueue.isEmpty)
    }

    /// The position a restored session shows is from before the app last went away. If the
    /// paired device carried that session on in the meantime, it has already counted those
    /// seconds — so giving up a session nobody played here credits nothing, which is also
    /// exactly what happened before sessions were saved.
    func testGivingUpARestoredSessionNobodyPlayedCreditsNothing() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 40)
        let relaunched = relaunch()

        relaunched.player.releaseSession()

        XCTAssertNil(relaunched.player.currentTrack)
        XCTAssertTrue(relaunched.sideEffects.listening.isEmpty)
    }

    /// Once it has been played here it is an ordinary session, and handing it on credits what
    /// was heard like any other handoff.
    func testGivingUpARestoredSessionThatWasPlayedCreditsIt() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 40)
        let relaunched = relaunch()
        relaunched.player.togglePlayPause()
        await relaunched.settle { relaunched.engine.attachCount == 1 && !relaunched.player.isLoading }
        relaunched.engine.tick(to: 100)

        relaunched.player.releaseSession()

        XCTAssertEqual(relaunched.sideEffects.listening.count, 1)
        XCTAssertEqual(relaunched.sideEffects.listening.first?.seconds, 100)
    }

    private func handedOver(_ id: String) -> NowPlayingCheckpoint {
        NowPlayingCheckpoint(
            peerId: "the-other-device",
            isDesktop: true,
            updatedAt: Date(),
            currentTrack: Fixtures.track(id),
            progress: 12,
            isPlaying: false,
            manualQueue: [],
            contextQueue: [],
            orderedContextQueue: [],
            isShuffling: false,
            queueContextTitle: nil,
            contextSeed: nil
        )
    }

    /// A session arriving from the paired device lands on a restored one as it would have
    /// landed before sessions were saved: on an empty player. Last night's track is not
    /// where "previous" leads from a queue it was never in, and nothing is credited for it.
    func testASessionHandedOverReplacesARestoredOneWhole() async {
        let list = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(list[0], context: list)
        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" && !self.harness.player.isLoading }
        harness.engine.tick(to: 30)
        let relaunched = relaunch()
        XCTAssertTrue(relaunched.player.hasPrevious, "Precondition: the restored session has a history")

        relaunched.player.adopt(checkpoint: handedOver("z"), autoplay: false)
        await relaunched.settle { relaunched.player.currentTrack?.videoId == "z" && !relaunched.player.isLoading }

        XCTAssertFalse(relaunched.player.hasPrevious)
        XCTAssertTrue(relaunched.player.contextQueue.isEmpty)
        XCTAssertTrue(relaunched.sideEffects.listening.isEmpty)
        XCTAssertEqual(relaunched.engine.currentTimeSeconds, 12, accuracy: 0.001)
    }

    /// The same handoff onto a session somebody *was* using here is unchanged: the track it
    /// replaces is credited and is where "previous" leads.
    func testASessionHandedOverOntoOneInUseStillLeadsBackToIt() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 30)

        harness.player.adopt(checkpoint: handedOver("z"), autoplay: false)
        await harness.settle { self.harness.player.currentTrack?.videoId == "z" && !self.harness.player.isLoading }

        XCTAssertTrue(harness.player.hasPrevious)
        XCTAssertEqual(harness.sideEffects.listening.first?.track.videoId, "a")
        XCTAssertEqual(harness.sideEffects.listening.first?.seconds, 30)
    }

    // MARK: - Only filling the blank

    /// A session that came back off disk is marked as one until somebody uses it. The paired
    /// device reads this to tell a queue someone is listening to from one that merely
    /// reappeared when an app was opened — see `FirstMeeting`.
    func testARestoredSessionSaysSoUntilItIsUsed() async {
        await harness.startPlaying(Fixtures.track("a"))
        XCTAssertNil(harness.player.restoredSessionSavedAt, "A session started in this run is in use by definition")

        var relaunched = relaunch()
        XCTAssertNotNil(relaunched.player.restoredSessionSavedAt)
        relaunched.player.togglePlayPause()
        XCTAssertNil(relaunched.player.restoredSessionSavedAt, "Pressing play is using it")

        relaunched = relaunchAfterBeingKilled()
        XCTAssertNotNil(relaunched.player.restoredSessionSavedAt)
        relaunched.player.seek(to: 10)
        XCTAssertNil(relaunched.player.restoredSessionSavedAt, "So is scrubbing")

        relaunched = relaunchAfterBeingKilled()
        XCTAssertNotNil(relaunched.player.restoredSessionSavedAt)
        relaunched.player.addToQueue(Fixtures.track("x"))
        XCTAssertNil(relaunched.player.restoredSessionSavedAt, "and so is queuing something behind it")
    }

    /// The peer wire carries dates to the second, and both devices have to weigh the same two
    /// numbers — so the figure is whole seconds here, where it starts.
    func testTheRestoredStampIsInWholeSeconds() {
        let saved = Fixtures.savedSession(savedAt: Date(timeIntervalSince1970: 1_700_000_000.75))

        let relaunched = PlayerHarness(sessionStore: FakeSessionStore(session: saved))

        XCTAssertEqual(relaunched.player.restoredSessionSavedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// The "continue from…" offer compares when each device's playback last changed. A queue
    /// from last night must not look like the newer of the two because its app was just
    /// opened.
    func testARestoredSessionIsAsOldAsItWasWhenItWasSaved() {
        let lastNight = Date(timeIntervalSinceNow: -12 * 60 * 60)
        let saved = Fixtures.savedSession(savedAt: lastNight)

        let relaunched = PlayerHarness(sessionStore: FakeSessionStore(session: saved))

        XCTAssertEqual(relaunched.player.nowPlayingCheckpoint().updatedAt, lastNight)
        XCTAssertFalse(relaunched.player.nowPlayingCheckpoint().isPlaying)
    }

    // MARK: - Guarding what came back

    /// Until play is pressed the engine holds nothing, and whatever it might report is not
    /// this track's position. A single tick of zero would otherwise erase the one thing the
    /// restore was for.
    func testATickFromAnEmptyEngineDoesNotWipeTheRestoredPosition() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 42)
        let relaunched = relaunch()

        relaunched.engine.tick(to: 0)

        XCTAssertEqual(relaunched.player.progress, 42, accuracy: 0.001)
        XCTAssertFalse(relaunched.player.isPlaying)
    }

    /// These numbers have been to disk and back. One that cannot be a position in the track
    /// is not handed to the player as a seek target.
    func testAPositionThatCannotBeRightComesBackAsTheTopOfTheTrack() {
        for position in [500.0, -4.0, .infinity, .nan] {
            let saved = Fixtures.savedSession(track: Fixtures.track("a", durationSeconds: 180),
                                              position: position, duration: 180)

            let relaunched = PlayerHarness(sessionStore: FakeSessionStore(session: saved))

            XCTAssertEqual(relaunched.player.currentTrack?.videoId, "a")
            XCTAssertEqual(relaunched.player.progress, 0, "\(position) was restored as a position")
        }
    }

    func testAFreshInstallStartsEmpty() {
        XCTAssertNil(harness.player.currentTrack)
        XCTAssertNil(harness.player.restoredSessionSavedAt)
        XCTAssertEqual(harness.sessionStore.sessionWrites, 0)
        XCTAssertEqual(harness.sessionStore.clears, 0)
    }
}

extension Fixtures {
    /// A session as it would be found on disk, defaulting to one track paused a minute in.
    static func savedSession(
        track: Track = Fixtures.track("a"),
        position: Double = 60,
        duration: Double = 180,
        savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        manualQueue: [Track] = [],
        contextQueue: [Track] = [],
        orderedContextQueue: [Track]? = nil,
        isShuffling: Bool = false
    ) -> SavedSession {
        SavedSession(
            savedAt: savedAt,
            currentTrack: track,
            position: position,
            duration: duration,
            manualQueue: manualQueue,
            contextQueue: contextQueue,
            orderedContextQueue: orderedContextQueue ?? contextQueue,
            isShuffling: isShuffling,
            queueContextTitle: nil,
            contextSeed: nil,
            currentTrackOrigin: .context,
            currentTrackOrderedIndex: 0,
            history: []
        )
    }
}
