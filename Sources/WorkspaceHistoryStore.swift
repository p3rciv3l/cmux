import Foundation
import Observation
import OSLog

private let workspaceHistoryLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "WorkspaceHistory"
)

@MainActor
@Observable
final class WorkspaceHistoryStore {
    static let shared = WorkspaceHistoryStore(
        capacity: 20,
        fileURL: defaultHistoryFileURL()
    )

    private(set) var revision: UInt64 = 0
    private var records: [WorkspaceHistoryRecord] = []
    private let capacity: Int
    private let fileURL: URL?
    private let persistsRecordsSynchronously: Bool
    private var didFinishPersistedRecordsLoad: Bool
    private var needsPersistenceAfterPersistedRecordsLoad = false

    init(
        capacity: Int = 20,
        fileURL: URL? = nil,
        loadPersisted: Bool = true,
        loadsPersistedRecordsSynchronously: Bool = false,
        persistsRecordsSynchronously: Bool = false
    ) {
        self.capacity = max(1, capacity)
        self.fileURL = fileURL
        self.persistsRecordsSynchronously = persistsRecordsSynchronously
        self.didFinishPersistedRecordsLoad = !loadPersisted || fileURL == nil
        if loadPersisted, let fileURL {
            if loadsPersistedRecordsSynchronously {
                records = Self.loadRecords(fileURL: fileURL)
                trimToCapacityIfNeeded()
                didFinishPersistedRecordsLoad = true
            } else {
                loadPersistedRecordsAsync(from: fileURL)
            }
        }
    }

    func listItems() -> [WorkspaceHistoryListItem] {
        records.reversed().map { record in
            WorkspaceHistoryListItem(
                id: record.id,
                title: record.title,
                detail: record.detail,
                stateTitle: stateTitle(for: record.state),
                updatedAt: record.updatedAt,
                state: record.state
            )
        }
    }

    func record(id: UUID) -> WorkspaceHistoryRecord? {
        records.first { $0.id == id }
    }

    func recordOpenWorkspace(
        _ workspace: Workspace,
        windowId: UUID?,
        workspaceIndex: Int?,
        touchExisting: Bool = false
    ) {
        let title = Self.title(for: workspace)
        let detail = Self.detail(forDirectory: workspace.currentDirectory)
        let existingIndex = records.firstIndex { $0.workspaceId == workspace.id }
        let existingRecord = existingIndex.map { records[$0] }
        let updatedAt: Date
        if touchExisting {
            updatedAt = Date()
        } else if let existingRecord {
            updatedAt = existingRecord.updatedAt
        } else {
            updatedAt = Date()
        }
        let id = existingRecord?.id ?? UUID()
        if let existingIndex {
            records.remove(at: existingIndex)
        }
        records.append(WorkspaceHistoryRecord(
            id: id,
            workspaceId: workspace.id,
            windowId: windowId,
            workspaceIndex: workspaceIndex,
            updatedAt: updatedAt,
            title: title,
            detail: detail,
            state: .open
        ))
        didMutateRecords()
    }

    func recordClosedWorkspace(
        _ entry: ClosedWorkspaceHistoryEntry,
        closedHistoryRecordId: UUID?
    ) {
        let existingIndex = records.firstIndex { $0.workspaceId == entry.workspaceId }
        let id = existingIndex.map { records[$0].id } ?? UUID()
        if let existingIndex {
            records.remove(at: existingIndex)
        }
        records.append(WorkspaceHistoryRecord(
            id: id,
            workspaceId: entry.workspaceId,
            windowId: entry.windowId,
            workspaceIndex: entry.workspaceIndex,
            updatedAt: Date(),
            title: Self.title(for: entry.snapshot),
            detail: Self.detail(forDirectory: entry.snapshot.currentDirectory),
            state: .closed,
            closedHistoryRecordId: closedHistoryRecordId,
            closedEntry: entry
        ))
        didMutateRecords()
    }

    func removeRecord(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records.remove(at: index)
        didMutateRecords()
    }

    func removeClosedWorkspaceRecord(workspaceId: UUID) {
        guard let index = records.firstIndex(where: {
            $0.workspaceId == workspaceId && $0.state == .closed
        }) else { return }
        records.remove(at: index)
        didMutateRecords()
    }

    private func didMutateRecords() {
        trimToCapacityIfNeeded()
        revision &+= 1
        persistRecords()
    }

    private func trimToCapacityIfNeeded() {
        guard records.count > capacity else { return }
        records.removeFirst(records.count - capacity)
    }

    private func persistRecords() {
        guard let fileURL else { return }
        guard didFinishPersistedRecordsLoad else {
            needsPersistenceAfterPersistedRecordsLoad = true
            return
        }
        let recordsSnapshot = records
        let revisionSnapshot = revision
        if persistsRecordsSynchronously {
            Self.saveRecords(recordsSnapshot, fileURL: fileURL)
        } else {
            Task {
                await WorkspaceHistoryPersistenceActor.shared.save(
                    recordsSnapshot,
                    fileURL: fileURL,
                    revision: revisionSnapshot
                )
            }
        }
    }

    private func loadPersistedRecordsAsync(from fileURL: URL) {
        Task { @MainActor [weak self] in
            let loadedRecords = await WorkspaceHistoryPersistenceActor.shared.load(fileURL: fileURL)
            guard let self, !didFinishPersistedRecordsLoad else { return }
            records = mergePersistedRecords(loadedRecords)
            didFinishPersistedRecordsLoad = true
            trimToCapacityIfNeeded()
            revision &+= 1
            if needsPersistenceAfterPersistedRecordsLoad {
                needsPersistenceAfterPersistedRecordsLoad = false
                persistRecords()
            }
        }
    }

    private func mergePersistedRecords(_ loadedRecords: [WorkspaceHistoryRecord]) -> [WorkspaceHistoryRecord] {
        guard !loadedRecords.isEmpty else { return records }
        var merged = loadedRecords
        let loadedIds = Set(loadedRecords.map(\.id))
        merged.append(contentsOf: records.filter { !loadedIds.contains($0.id) })
        return merged
    }

    private func stateTitle(for state: WorkspaceHistoryRecordState) -> String {
        switch state {
        case .open:
            return String(localized: "workspaceHistory.state.open", defaultValue: "Open")
        case .closed:
            return String(localized: "workspaceHistory.state.closed", defaultValue: "Closed")
        }
    }

    private static func title(for workspace: Workspace) -> String {
        let candidates = [
            workspace.customTitle,
            Optional(workspace.title),
            detail(forDirectory: workspace.currentDirectory)
        ]
        if let title = candidates.compactMap({ normalizedTitleCandidate($0) })
            .first(where: { !$0.isEmpty }) {
            return title
        }
        return String(localized: "menu.history.untitledWorkspace", defaultValue: "Untitled Workspace")
    }

    private static func title(for snapshot: SessionWorkspaceSnapshot) -> String {
        let candidates = [
            snapshot.customTitle,
            Optional(snapshot.processTitle),
            detail(forDirectory: snapshot.currentDirectory)
        ]
        if let title = candidates.compactMap({ normalizedTitleCandidate($0) })
            .first(where: { !$0.isEmpty }) {
            return title
        }
        return String(localized: "menu.history.untitledWorkspace", defaultValue: "Untitled Workspace")
    }

    private static func detail(forDirectory directory: String) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "." else { return nil }
        return trimmed
    }

    private static func normalizedTitleCandidate(_ candidate: String?) -> String? {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "." else { return nil }
        return trimmed
    }

    nonisolated fileprivate static func loadRecords(fileURL: URL) -> [WorkspaceHistoryRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        if let snapshot = try? decoder.decode(WorkspaceHistoryPersistenceSnapshot.self, from: data),
           snapshot.version == WorkspaceHistoryPersistenceSnapshot.currentVersion {
            return snapshot.records
        }
        return (try? decoder.decode([WorkspaceHistoryRecord].self, from: data)) ?? []
    }

    nonisolated fileprivate static func saveRecords(_ records: [WorkspaceHistoryRecord], fileURL: URL) {
        guard !records.isEmpty else {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    workspaceHistoryLogger.debug(
                        "workspaceHistory.remove.failed file=\(fileURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let snapshot = WorkspaceHistoryPersistenceSnapshot(records: records)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            if let existingData = try? Data(contentsOf: fileURL), existingData == data {
                return
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            workspaceHistoryLogger.debug(
                "workspaceHistory.save.failed file=\(fileURL.path, privacy: .public) records=\(records.count) error=\(error.localizedDescription, privacy: .public)"
            )
            return
        }
    }

    nonisolated private static func defaultHistoryFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        guard !isRunningUnderAutomatedTests else { return nil }
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.cmuxterm.app"
        let safeBundleId = bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return resolvedAppSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("workspace-history-\(safeBundleId).json", isDirectory: false)
    }
}

private struct WorkspaceHistoryPersistenceSnapshot: Codable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var records: [WorkspaceHistoryRecord]
}

private actor WorkspaceHistoryPersistenceActor {
    static let shared = WorkspaceHistoryPersistenceActor()

    private var latestRevisionByPath: [String: UInt64] = [:]

    func load(fileURL: URL) -> [WorkspaceHistoryRecord] {
        WorkspaceHistoryStore.loadRecords(fileURL: fileURL)
    }

    func save(_ records: [WorkspaceHistoryRecord], fileURL: URL, revision: UInt64) {
        let path = fileURL.standardizedFileURL.path
        if let latestRevision = latestRevisionByPath[path], revision < latestRevision {
            return
        }
        latestRevisionByPath[path] = revision
        WorkspaceHistoryStore.saveRecords(records, fileURL: fileURL)
    }
}
