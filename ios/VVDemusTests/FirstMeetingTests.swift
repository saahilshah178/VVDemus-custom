import XCTest
@testable import VVDemus

/// Which device keeps its session when the two first see each other.
///
/// The failure mode is loud and immediate — the music stops mid-song on the device someone is
/// listening to, because the other one decided it was in charge — and it is only reachable by
/// arranging two devices in a particular pair of states at the moment they connect. That is
/// exactly the kind of thing that is answered here instead.
///
/// The property that matters most is **symmetry**: both devices run this independently, and if
/// they can both conclude they won, two sessions play at once.
@MainActor
final class FirstMeetingTests: XCTestCase {
    private func meeting(
        localPlaying: Bool,
        peerPlaying: Bool,
        localDesktop: Bool = false,
        peerDesktop: Bool = true,
        localId: String = "peer-aaa",
        peerId: String = "peer-zzz",
        localRestoredAt: Date? = nil,
        peerRestoredAt: Date? = nil
    ) -> FirstMeeting {
        FirstMeeting(
            localIsPlaying: localPlaying,
            peerIsPlaying: peerPlaying,
            localIsDesktop: localDesktop,
            peerIsDesktop: peerDesktop,
            localPeerId: localId,
            peerPeerId: peerId,
            localRestoredAt: localRestoredAt,
            peerRestoredAt: peerRestoredAt
        )
    }

    private let lastNight = Date(timeIntervalSince1970: 1_700_000_000)
    private let thisMorning = Date(timeIntervalSince1970: 1_700_040_000)

    /// Whatever the two devices are, exactly one of them must come away with the session.
    private func assertSymmetric(
        _ m: FirstMeeting,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let mirrored = FirstMeeting(
            localIsPlaying: m.peerIsPlaying,
            peerIsPlaying: m.localIsPlaying,
            localIsDesktop: m.peerIsDesktop,
            peerIsDesktop: m.localIsDesktop,
            localPeerId: m.peerPeerId,
            peerPeerId: m.localPeerId,
            localRestoredAt: m.peerRestoredAt,
            peerRestoredAt: m.localRestoredAt
        )
        XCTAssertNotEqual(
            m.localKeepsSession,
            mirrored.localKeepsSession,
            "both devices decided the same way — that is either two sessions playing at once, or none",
            file: file,
            line: line
        )
    }

    func testTheDevicePlayingKeepsTheSession() {
        XCTAssertTrue(meeting(localPlaying: true, peerPlaying: false).localKeepsSession)
        XCTAssertFalse(meeting(localPlaying: false, peerPlaying: true).localKeepsSession)
    }

    /// Playing beats being a desktop. The phone here is the one making sound and the peer is a
    /// Mac; the Mac must not interrupt it just for being a Mac.
    func testPlayingBeatsTheDesktopTiebreak() {
        let phonePlayingAgainstIdleMac = meeting(
            localPlaying: true, peerPlaying: false, localDesktop: false, peerDesktop: true
        )
        XCTAssertTrue(phonePlayingAgainstIdleMac.localKeepsSession)
        assertSymmetric(phonePlayingAgainstIdleMac)
    }

    func testTheDesktopBreaksATieWhenBothArePlaying() {
        let phone = meeting(localPlaying: true, peerPlaying: true, localDesktop: false, peerDesktop: true)
        XCTAssertFalse(phone.localKeepsSession, "the Mac is the device you are sat in front of")
        assertSymmetric(phone)
    }

    func testTheDesktopBreaksATieWhenBothArePaused() {
        let phone = meeting(localPlaying: false, peerPlaying: false, localDesktop: false, peerDesktop: true)
        XCTAssertFalse(phone.localKeepsSession)
        assertSymmetric(phone)
    }

    /// Two devices of the same kind — a Mac paired to a Mac, or a phone to a phone — have no
    /// desktop tiebreak left, so the ids decide. Any answer will do provided both reach it.
    func testTwoDevicesOfTheSameKindStillAgree() {
        let bothMacsPaused = meeting(
            localPlaying: false, peerPlaying: false,
            localDesktop: true, peerDesktop: true,
            localId: "peer-aaa", peerId: "peer-zzz"
        )
        XCTAssertFalse(bothMacsPaused.localKeepsSession)
        assertSymmetric(bothMacsPaused)

        let bothPhonesPlaying = meeting(
            localPlaying: true, peerPlaying: true,
            localDesktop: false, peerDesktop: false,
            localId: "peer-zzz", peerId: "peer-aaa"
        )
        XCTAssertTrue(bothPhonesPlaying.localKeepsSession)
        assertSymmetric(bothPhonesPlaying)
    }

    // MARK: - A session that only came back off disk

    /// The case the clause exists for. The Mac app is opened and last night's queue comes back
    /// with it, paused; the phone is holding what was listened to on the way home, also paused.
    /// The desktop rule alone gives the Mac the session and the phone lets its own go — and
    /// before sessions were saved, the freshly opened Mac held nothing and mirrored the phone.
    func testASessionInUseBeatsOneThatOnlyCameBackOffDisk() {
        let macJustOpened = meeting(
            localPlaying: false, peerPlaying: false, localDesktop: true, peerDesktop: false,
            localRestoredAt: lastNight
        )
        XCTAssertFalse(macJustOpened.localKeepsSession, "Opening the Mac app took the session from the phone")
        assertSymmetric(macJustOpened)

        let phoneMeetingIt = meeting(
            localPlaying: false, peerPlaying: false, localDesktop: false, peerDesktop: true,
            peerRestoredAt: lastNight
        )
        XCTAssertTrue(phoneMeetingIt.localKeepsSession)
    }

    /// A restored session that has been used is an ordinary one again — its stamp is gone —
    /// so the rules are exactly what they were.
    func testOnceUsedARestoredSessionIsWeighedLikeAnyOther() {
        let mac = meeting(localPlaying: false, peerPlaying: false, localDesktop: true, peerDesktop: false)
        XCTAssertTrue(mac.localKeepsSession)
    }

    /// Playing still comes first. Nothing restored is ever playing, so this is the one order
    /// the two clauses can be in — but it is the order that must hold if that ever changes.
    func testPlayingStillBeatsEverything() {
        let playingAgainstRestored = meeting(
            localPlaying: true, peerPlaying: false, localDesktop: false, peerDesktop: true,
            peerRestoredAt: lastNight
        )
        XCTAssertTrue(playingAgainstRestored.localKeepsSession)
        assertSymmetric(playingAgainstRestored)
    }

    /// Both apps were opened since anything was played, so both sessions came off disk. The
    /// one saved later is the one that was listened to last, whichever device it is on.
    func testOfTwoRestoredSessionsTheOneSavedLaterIsKept() {
        let phoneWithTheNewerOne = meeting(
            localPlaying: false, peerPlaying: false, localDesktop: false, peerDesktop: true,
            localRestoredAt: thisMorning, peerRestoredAt: lastNight
        )
        XCTAssertTrue(phoneWithTheNewerOne.localKeepsSession, "The desktop took it with the older queue")
        assertSymmetric(phoneWithTheNewerOne)
    }

    /// Saved in the same second — the wire carries no finer than that — leaves nothing to
    /// choose between them on age, and the ordinary tiebreaks still give exactly one answer.
    func testTwoRestoredSessionsOfTheSameAgeFallBackToTheDesktop() {
        let phone = meeting(
            localPlaying: false, peerPlaying: false, localDesktop: false, peerDesktop: true,
            localRestoredAt: lastNight, peerRestoredAt: lastNight
        )
        XCTAssertFalse(phone.localKeepsSession)
        assertSymmetric(phone)
    }

    /// The whole table, both ways round. Any clause that ever prefers "me" rather than comparing
    /// the two sides shows up here as both devices keeping the session.
    func testExactlyOneDeviceEverKeepsTheSession() {
        let stamps: [Date?] = [nil, lastNight, thisMorning]
        for localPlaying in [true, false] {
            for peerPlaying in [true, false] {
                for localDesktop in [true, false] {
                    for peerDesktop in [true, false] {
                        for localRestoredAt in stamps {
                            for peerRestoredAt in stamps {
                                assertSymmetric(meeting(
                                    localPlaying: localPlaying,
                                    peerPlaying: peerPlaying,
                                    localDesktop: localDesktop,
                                    peerDesktop: peerDesktop,
                                    localRestoredAt: localRestoredAt,
                                    peerRestoredAt: peerRestoredAt
                                ))
                            }
                        }
                    }
                }
            }
        }
    }
}
