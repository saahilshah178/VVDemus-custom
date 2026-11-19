import Foundation

/// The session, in the shape it is written down in so that it outlives the app.
///
/// Nothing was written down before. A queue lived in `PlayerService` and nowhere else, so
/// quitting the app ended it — and so did leaving a phone alone for long enough, which looks
/// like the app "resetting itself" and is the same thing: iOS suspends an app that is paused
/// in the background and later ends it, and the next launch is a cold one.
///
/// Its own type rather than `NowPlayingCheckpoint`, which is nearly the same list of fields.
/// That one is a wire format shared with whatever build the paired device happens to be
/// running; this one is read only by the device that wrote it, and it carries what a handoff
/// has never needed — where "previous" leads, and which queue the current track came out of.
struct SavedSession: Codable, Equatable {
    /// Bumped only when the shape changes — see `LyricsCacheStore.schemaVersion`, which is
    /// here for the same reason: it is what lets an older build recognise a file written by a
    /// newer one and start empty instead of misreading it.
    static let currentVersion = 1

    var version = SavedSession.currentVersion
    var savedAt: Date

    var currentTrack: Track
    /// Where the track had got to when this was written. `SavedPosition` is written far more
    /// often and is the better source whenever it describes the same track.
    var position: Double
    var duration: Double

    var manualQueue: [Track]
    var contextQueue: [Track]
    /// The unshuffled order, which is what switching shuffle off restores.
    var orderedContextQueue: [Track]
    var isShuffling: Bool
    var queueContextTitle: String?
    var contextSeed: Track?

    var currentTrackOrigin: PlayerService.QueueOrigin
    var currentTrackOrderedIndex: Int
    /// The tracks "previous" walks back through, oldest first.
    var history: [Played]

    struct Played: Codable, Equatable {
        var track: Track
        var origin: PlayerService.QueueOrigin
        var orderedIndex: Int
    }
}

/// How far into the current track playback has got, written on its own.
///
/// Separate from `SavedSession` because of how often each changes. The queue changes when a
/// track ends or someone edits it; the position changes continuously. Rewriting the whole
/// session to move one number would mean encoding a few hundred tracks every few seconds for
/// as long as music played.
struct SavedPosition: Codable, Equatable {
    var videoId: String
    var position: Double
    var duration: Double
    var savedAt: Date
}

extension SavedSession {
    /// This session with `mark` laid over it, when `mark` is news about it.
    ///
    /// Two conditions, and the second is the one that is easy to leave out. A position for
    /// another track is obviously not this one's — the two files are written separately, so
    /// for a moment at every track boundary they describe different songs. But a position
    /// for the *same* track can be the older of the two as well: the session is rewritten
    /// whenever the queue is edited, carrying the position as it was at that moment, and a
    /// mark written before the edit is behind it.
    func overlaying(_ mark: SavedPosition?) -> SavedSession {
        guard let mark, mark.videoId == currentTrack.videoId, mark.savedAt >= savedAt else { return self }
        var result = self
        result.position = mark.position
        if mark.duration > 0 { result.duration = mark.duration }
        return result
    }

    /// The track's length: the player's own measurement when one was saved, the track's
    /// metadata otherwise, zero when neither is known.
    var resumeDuration: Double {
        if let measured = PlayerService.sanitisedSeconds(duration), measured > 0 { return measured }
        return currentTrack.durationSeconds.map(Double.init) ?? 0
    }

    /// Where to pick the track back up.
    ///
    /// The top of the track whenever the saved figure cannot be a position in it. These
    /// numbers have been to disk and back, and one that is not finite, or lies past the end,
    /// would otherwise be handed to the player as a seek target.
    var resumePosition: Double {
        guard let position = PlayerService.sanitisedSeconds(position) else { return 0 }
        let length = resumeDuration
        guard length > 0 else { return position }
        return position < length ? position : 0
    }
}

extension SavedPosition {
    /// How far playback may move before its position is written down again, in seconds of
    /// the track.
    ///
    /// It is the most a relaunch can be out by after the app is ended with no warning at
    /// all — a crash, a force quit, the battery. Every ending that does come with a warning
    /// writes the exact position instead.
    static let writeInterval: Double = 5

    /// Whether `position` in `videoId` is far enough from what is on disk to be worth a write.
    ///
    /// Measured in distance rather than time on purpose: the periodic tick, a scrub and a
    /// casting browser's reports all move the position, and "it has moved five seconds from
    /// what was written" covers all three without a clock. A scrub is a jump and is written
    /// at once; ordinary playback crosses the line once every five seconds.
    static func isWorthWriting(
        _ position: Double,
        videoId: String,
        lastWritten: (videoId: String, position: Double)?
    ) -> Bool {
        guard let lastWritten, lastWritten.videoId == videoId else { return true }
        return abs(position - lastWritten.position) >= writeInterval
    }
}
