import AppKit
import SwiftUI

@MainActor
final class WorkspaceHistoryWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WorkspaceHistoryWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "workspaceHistory.window.title", defaultValue: "Workspaces")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.workspaceHistory")
        window.center()
        window.contentView = NSHostingView(
            rootView: WorkspaceHistorySelectorView(
                store: WorkspaceHistoryStore.shared,
                openRecord: { id in
                    AppDelegate.shared?.openWorkspaceHistoryRecord(id: id) == true
                }
            )
        )
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
