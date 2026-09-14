import Foundation

extension TerminalController {
    func v2BrowserMediaCommand(method: BrowserMediaSocketMethod, params: [String: Any]) -> V2CallResult {
        guard
            let rawLeaseID = params["lease_id"] as? String,
            let leaseID = BrowserMediaSuspensionLeaseID(rawLeaseID)
        else {
            return .err(code: "invalid_params", message: "Missing or invalid lease_id", data: nil)
        }

        switch method {
        case .suspendAll:
            guard let app = AppDelegate.shared else {
                return .err(code: "unavailable", message: "Application is unavailable", data: nil)
            }

            var webViews: [any BrowserMediaPlaybackTarget] = []
            for summary in app.listMainWindowSummaries() {
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }
                for workspace in manager.tabs {
                    webViews.append(contentsOf: workspace.panels.values.compactMap {
                        ($0 as? BrowserPanel)?.webView
                    })
                }
            }

            let result = browserMediaSuspensionCoordinator.suspend(leaseID: leaseID, targets: webViews)
            return .ok(["lease_id": leaseID.rawValue, "candidate_count": result.candidateCount])

        case .resumeAll:
            let resumedCount = browserMediaSuspensionCoordinator.resume(leaseID: leaseID)
            return .ok(["lease_id": leaseID.rawValue, "resumed_count": resumedCount])
        }
    }
}
