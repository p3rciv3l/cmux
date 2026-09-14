import Foundation

enum WorkspaceHistoryRecordState: String, Codable {
    case open
    case closed
}

struct WorkspaceHistoryRecord: Identifiable, Codable {
    var id: UUID
    var workspaceId: UUID
    var windowId: UUID?
    var workspaceIndex: Int?
    var updatedAt: Date
    var title: String
    var detail: String?
    var state: WorkspaceHistoryRecordState
    var closedHistoryRecordId: UUID?
    var closedEntry: ClosedWorkspaceHistoryEntry?

    init(
        id: UUID = UUID(),
        workspaceId: UUID,
        windowId: UUID?,
        workspaceIndex: Int?,
        updatedAt: Date = Date(),
        title: String,
        detail: String?,
        state: WorkspaceHistoryRecordState,
        closedHistoryRecordId: UUID? = nil,
        closedEntry: ClosedWorkspaceHistoryEntry? = nil
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.windowId = windowId
        self.workspaceIndex = workspaceIndex
        self.updatedAt = updatedAt
        self.title = title
        self.detail = detail
        self.state = state
        self.closedHistoryRecordId = closedHistoryRecordId
        self.closedEntry = closedEntry
    }
}

struct WorkspaceHistoryListItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let detail: String?
    let stateTitle: String
    let updatedAt: Date
    let state: WorkspaceHistoryRecordState
}
