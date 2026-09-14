import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserMediaSuspensionTests {
    @Test func suspensionSessionPausesEveryPlayingTargetAndRestoresOnlyThoseTargets() throws {
        let coordinator = BrowserMediaSuspensionCoordinator()
        let firstPlaying = BrowserMediaPlaybackTargetSpy(state: .playing)
        let alreadyPaused = BrowserMediaPlaybackTargetSpy(state: .paused)
        let secondPlaying = BrowserMediaPlaybackTargetSpy(state: .playing)

        let result = coordinator.suspend(
            leaseID: try #require(BrowserMediaSuspensionLeaseID("freeflow")),
            targets: [firstPlaying, alreadyPaused, secondPlaying]
        )
        firstPlaying.completePlaybackStateRequest()
        alreadyPaused.completePlaybackStateRequest()
        secondPlaying.completePlaybackStateRequest()

        #expect(result.candidateCount == 3)
        #expect(firstPlaying.suspensionChanges == [true])
        #expect(alreadyPaused.suspensionChanges.isEmpty)
        #expect(secondPlaying.suspensionChanges == [true])

        let resumedCount = coordinator.resume(
            leaseID: try #require(BrowserMediaSuspensionLeaseID("freeflow"))
        )

        #expect(resumedCount == 2)
        #expect(firstPlaying.suspensionChanges == [true, false])
        #expect(alreadyPaused.suspensionChanges.isEmpty)
        #expect(secondPlaying.suspensionChanges == [true, false])
    }

    @Test func releaseBeforePlaybackSnapshotCompletesCannotPauseLater() throws {
        let coordinator = BrowserMediaSuspensionCoordinator()
        let delayedPlaying = BrowserMediaPlaybackTargetSpy(state: .playing)
        let leaseID = try #require(BrowserMediaSuspensionLeaseID("freeflow"))

        _ = coordinator.suspend(leaseID: leaseID, targets: [delayedPlaying])
        #expect(coordinator.resume(leaseID: leaseID) == 0)
        delayedPlaying.completePlaybackStateRequest()

        #expect(delayedPlaying.suspensionChanges.isEmpty)
    }

    @Test func releaseCommandArrivingBeforeSuspendCommandCancelsThatSession() throws {
        let coordinator = BrowserMediaSuspensionCoordinator()
        let playing = BrowserMediaPlaybackTargetSpy(state: .playing)
        let leaseID = try #require(BrowserMediaSuspensionLeaseID("freeflow-unique-session"))

        #expect(coordinator.resume(leaseID: leaseID) == 0)
        let result = coordinator.suspend(leaseID: leaseID, targets: [playing])

        #expect(result.candidateCount == 0)
        #expect(playing.suspensionChanges.isEmpty)
    }

    @Test func independentLeasesDoNotResumeEachOthersSuspension() throws {
        let coordinator = BrowserMediaSuspensionCoordinator()
        let playing = BrowserMediaPlaybackTargetSpy(state: .playing)
        let freeflowLease = try #require(BrowserMediaSuspensionLeaseID("freeflow"))
        let otherLease = try #require(BrowserMediaSuspensionLeaseID("other-client"))

        _ = coordinator.suspend(leaseID: freeflowLease, targets: [playing])
        playing.completePlaybackStateRequest()
        playing.state = .suspended
        _ = coordinator.suspend(leaseID: otherLease, targets: [playing])
        playing.completePlaybackStateRequest()

        #expect(playing.suspensionChanges == [true])
        #expect(coordinator.resume(leaseID: freeflowLease) == 1)
        #expect(playing.suspensionChanges == [true])
        #expect(coordinator.resume(leaseID: otherLease) == 1)
        #expect(playing.suspensionChanges == [true, false])
    }
}

@MainActor
private final class BrowserMediaPlaybackTargetSpy: BrowserMediaPlaybackTarget {
    var state: WKMediaPlaybackState
    var suspensionChanges: [Bool] = []
    private var pendingStateRequests: [(WKMediaPlaybackState) -> Void] = []

    init(state: WKMediaPlaybackState) {
        self.state = state
    }

    func cmuxRequestMediaPlaybackState(_ completion: @escaping (WKMediaPlaybackState) -> Void) {
        pendingStateRequests.append(completion)
    }

    func cmuxSetAllMediaPlaybackSuspended(_ suspended: Bool) {
        suspensionChanges.append(suspended)
    }

    func completePlaybackStateRequest() {
        pendingStateRequests.removeFirst()(state)
    }
}
