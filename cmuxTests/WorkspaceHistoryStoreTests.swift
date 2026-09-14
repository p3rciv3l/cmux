import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace history store")
struct WorkspaceHistoryStoreTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func trimsToCapacityAndPersistsNewestRecords() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("workspace-history.json")
        let store = WorkspaceHistoryStore(
            capacity: 2,
            fileURL: fileURL,
            loadPersisted: false,
            persistsRecordsSynchronously: true
        )

        store.recordClosedWorkspace(
            makeClosedWorkspaceEntry(
                workspaceId: UUID(),
                title: "One",
                directory: "/tmp/one"
            ),
            closedHistoryRecordId: UUID()
        )
        store.recordClosedWorkspace(
            makeClosedWorkspaceEntry(
                workspaceId: UUID(),
                title: "Two",
                directory: "/tmp/two"
            ),
            closedHistoryRecordId: UUID()
        )
        store.recordClosedWorkspace(
            makeClosedWorkspaceEntry(
                workspaceId: UUID(),
                title: "Three",
                directory: "/tmp/three"
            ),
            closedHistoryRecordId: UUID()
        )

        let items = store.listItems()
        #expect(items.map(\.title) == ["Three", "Two"])
        #expect(items.map(\.state) == [.closed, .closed])

        let data = try Data(contentsOf: fileURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        let records = try #require(object["records"] as? [[String: Any]])
        #expect(records.count == 2)
        #expect(records.compactMap { $0["title"] as? String } == ["Two", "Three"])
    }

    private func makeClosedWorkspaceEntry(
        workspaceId: UUID,
        title: String,
        directory: String
    ) -> ClosedWorkspaceHistoryEntry {
        ClosedWorkspaceHistoryEntry(
            workspaceId: workspaceId,
            windowId: UUID(),
            workspaceIndex: 0,
            snapshot: SessionWorkspaceSnapshot(
                workspaceId: workspaceId,
                processTitle: title,
                customTitle: title,
                customDescription: nil,
                customColor: nil,
                isPinned: false,
                terminalScrollBarHidden: nil,
                currentDirectory: directory,
                focusedPanelId: nil,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
                panels: [],
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil,
                remote: nil
            )
        )
    }
}
