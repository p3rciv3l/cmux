import AppKit
import SwiftUI

struct WorkspaceHistorySelectorView: View {
    let store: WorkspaceHistoryStore
    let openRecord: (UUID) -> Bool
    @State private var selectedRecordId: UUID?

    var body: some View {
        let items = store.listItems()

        VStack(spacing: 0) {
            if items.isEmpty {
                Text(String(localized: "workspaceHistory.empty", defaultValue: "No workspace history yet"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in
                            Button {
                                selectedRecordId = item.id
                                if !openRecord(item.id) {
                                    NSSound.beep()
                                }
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(item.id == selectedRecordId ? Color.yellow : Color.primary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        if let detail = item.detail {
                                            Text(detail)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    Spacer(minLength: 12)
                                    Text(item.stateTitle)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 260, idealHeight: 380)
        .focusable()
        .onAppear {
            selectedRecordId = selectedRecordId ?? items.first?.id
        }
        .onChange(of: items.map(\.id)) { _, ids in
            if let selectedRecordId, ids.contains(selectedRecordId) {
                return
            }
            selectedRecordId = ids.first
        }
        .onMoveCommand { direction in
            moveSelection(direction: direction, items: items)
        }
        .overlay(alignment: .bottomTrailing) {
            Button(String(localized: "workspaceHistory.openSelected", defaultValue: "Open")) {
                openSelected(items: items)
            }
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func moveSelection(direction: MoveCommandDirection, items: [WorkspaceHistoryListItem]) {
        guard !items.isEmpty else {
            selectedRecordId = nil
            return
        }
        let currentIndex = selectedRecordId.flatMap { id in
            items.firstIndex { $0.id == id }
        } ?? 0
        let nextIndex: Int
        switch direction {
        case .up:
            nextIndex = max(0, currentIndex - 1)
        case .down:
            nextIndex = min(items.count - 1, currentIndex + 1)
        default:
            nextIndex = currentIndex
        }
        selectedRecordId = items[nextIndex].id
    }

    private func openSelected(items: [WorkspaceHistoryListItem]) {
        guard let selectedRecordId else { return }
        if !openRecord(selectedRecordId) {
            NSSound.beep()
        }
    }
}
