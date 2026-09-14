import AppKit

extension AppDelegate {
    @MainActor
    func showWorkspaceHistorySelector() {
        syncOpenWorkspacesIntoWorkspaceHistory()
        WorkspaceHistoryWindowController.shared.show()
    }

    @MainActor
    @discardableResult
    func openWorkspaceHistoryRecord(id: UUID) -> Bool {
        guard let record = WorkspaceHistoryStore.shared.record(id: id) else {
            return false
        }

        switch record.state {
        case .open:
            return openLiveWorkspaceHistoryRecord(record)
        case .closed:
            return restoreClosedWorkspaceHistoryRecord(record)
        }
    }

    @MainActor
    func syncOpenWorkspacesIntoWorkspaceHistory() {
        let store = WorkspaceHistoryStore.shared
        for summary in listMainWindowSummaries() {
            guard let manager = tabManagerFor(windowId: summary.windowId) else { continue }
            for (index, workspace) in manager.tabs.enumerated() {
                store.recordOpenWorkspace(
                    workspace,
                    windowId: summary.windowId,
                    workspaceIndex: index
                )
            }
        }
    }

    @MainActor
    private func openLiveWorkspaceHistoryRecord(_ record: WorkspaceHistoryRecord) -> Bool {
        guard let manager = tabManagerFor(tabId: record.workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == record.workspaceId }) else {
            WorkspaceHistoryStore.shared.removeRecord(id: record.id)
            return false
        }

        if let windowId = windowId(for: manager) {
            _ = focusMainWindow(windowId: windowId)
        }
        TerminalController.shared.setActiveTabManager(manager)
        manager.selectWorkspace(workspace)
        WorkspaceHistoryStore.shared.recordOpenWorkspace(
            workspace,
            windowId: windowId(for: manager),
            workspaceIndex: manager.tabs.firstIndex(where: { $0.id == workspace.id }),
            touchExisting: true
        )
        return true
    }

    @MainActor
    private func restoreClosedWorkspaceHistoryRecord(_ record: WorkspaceHistoryRecord) -> Bool {
        if let closedHistoryRecordId = record.closedHistoryRecordId,
           reopenClosedHistoryItem(id: closedHistoryRecordId, shouldActivate: true) {
            WorkspaceHistoryStore.shared.removeRecord(id: record.id)
            syncOpenWorkspacesIntoWorkspaceHistory()
            return true
        }

        guard let entry = record.closedEntry else {
            WorkspaceHistoryStore.shared.removeRecord(id: record.id)
            return false
        }

        let manager =
            entry.windowId.flatMap { tabManagerFor(windowId: $0) }
            ?? tabManagerFor(tabId: record.workspaceId)
            ?? tabManager
            ?? mainWindowContexts.values.first?.tabManager

        guard let manager, manager.restoreClosedWorkspace(entry) else {
            return false
        }

        if let windowId = windowId(for: manager) {
            _ = focusMainWindow(windowId: windowId)
        }
        TerminalController.shared.setActiveTabManager(manager)
        WorkspaceHistoryStore.shared.removeRecord(id: record.id)
        syncOpenWorkspacesIntoWorkspaceHistory()
        return true
    }
}
