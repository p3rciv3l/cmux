import Foundation
import WebKit

/// Owns paired WebKit suspensions and restores only media captured by each lease.
@MainActor
final class BrowserMediaSuspensionCoordinator {
    struct SuspensionStartResult: Equatable {
        let candidateCount: Int
    }

    private struct Session {
        let generation: UUID
        var targetIDs: Set<ObjectIdentifier> = []
    }

    private struct TargetRecord {
        let target: WeakBrowserMediaPlaybackTarget
        var leases: Set<BrowserMediaSuspensionLeaseID>
    }

    private var sessions: [BrowserMediaSuspensionLeaseID: Session] = [:]
    private var targets: [ObjectIdentifier: TargetRecord] = [:]
    private var cancelledLeases: Set<BrowserMediaSuspensionLeaseID> = []

    @discardableResult
    func suspend(
        leaseID: BrowserMediaSuspensionLeaseID,
        targets candidateTargets: [any BrowserMediaPlaybackTarget]
    ) -> SuspensionStartResult {
        // Socket requests are independent connections and can arrive out of order.
        if cancelledLeases.remove(leaseID) != nil {
            return SuspensionStartResult(candidateCount: 0)
        }
        guard sessions[leaseID] == nil else {
            return SuspensionStartResult(candidateCount: 0)
        }

        let generation = UUID()
        var seen: Set<ObjectIdentifier> = []
        let uniqueTargets = candidateTargets.filter { seen.insert(ObjectIdentifier($0)).inserted }
        sessions[leaseID] = Session(generation: generation)

        for target in uniqueTargets {
            let weakTarget = WeakBrowserMediaPlaybackTarget(target)
            target.cmuxRequestMediaPlaybackState { [weak self] state in
                guard let self, let target = weakTarget.value else { return }
                self.capture(target: target, state: state, leaseID: leaseID, generation: generation)
            }
        }

        return SuspensionStartResult(candidateCount: uniqueTargets.count)
    }

    @discardableResult
    func resume(leaseID: BrowserMediaSuspensionLeaseID) -> Int {
        guard let session = sessions.removeValue(forKey: leaseID) else {
            cancelledLeases.insert(leaseID)
            if cancelledLeases.count > 256, let arbitraryExpiredLease = cancelledLeases.first {
                cancelledLeases.remove(arbitraryExpiredLease)
            }
            return 0
        }

        for targetID in session.targetIDs {
            guard var record = targets[targetID] else { continue }
            record.leases.remove(leaseID)
            if record.leases.isEmpty {
                record.target.value?.cmuxSetAllMediaPlaybackSuspended(false)
                targets.removeValue(forKey: targetID)
            } else {
                targets[targetID] = record
            }
        }
        return session.targetIDs.count
    }

    private func capture(
        target: any BrowserMediaPlaybackTarget,
        state: WKMediaPlaybackState,
        leaseID: BrowserMediaSuspensionLeaseID,
        generation: UUID
    ) {
        guard var session = sessions[leaseID], session.generation == generation else { return }

        let targetID = ObjectIdentifier(target)
        let alreadySuspendedByCmux = targets[targetID]?.leases.isEmpty == false
        guard state == .playing || (state == .suspended && alreadySuspendedByCmux) else { return }
        guard session.targetIDs.insert(targetID).inserted else { return }
        sessions[leaseID] = session

        if var record = targets[targetID] {
            record.leases.insert(leaseID)
            targets[targetID] = record
        } else {
            target.cmuxSetAllMediaPlaybackSuspended(true)
            targets[targetID] = TargetRecord(
                target: WeakBrowserMediaPlaybackTarget(target),
                leases: [leaseID]
            )
        }
    }
}
