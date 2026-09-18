import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises the real shortcut dispatcher with unposted events and owned window contexts.
/// Run separately from suites that replace the app's process-global settings store.
@Suite(.serialized)
@MainActor
struct AppDelegateTilingShortcutTests {
    @Test(arguments: PaneTilingAction.allCases, [false, true])
    func configuredActionDispatchesOnceAndPreservesPaneContents(action: PaneTilingAction, useDefault: Bool) throws {
        try withEnvironment { app, configURL in
            let shortcutAction = try #require(KeyboardShortcutSettings.tilingActions.first { $0.tilingAction == action })
            if useDefault {
                // Exercise fallback defaults with every real neighboring binding enabled.
                try JSONSerialization.data(withJSONObject: ["schemaVersion": 1]).write(to: configURL, options: .atomic)
                KeyboardShortcutSettings.settingsFileStore.reload()
            } else {
                try configure(configURL, bindings: [shortcutAction.rawValue: "cmd+ctrl+opt+t"])
            }
            try withWorkspace(app) { window, _, workspace in
                let controller = workspace.bonsplitController
                let manualPanes = controller.layoutSnapshot().panes
                if action != .tile { #expect(workspace.performTilingAction(.tile)) }
                let order = controller.allPaneIds
                #expect(order.count == 3)
                controller.focusPane(order[1])
                let tabs = Set(controller.allTabIds)
                let panels = workspace.panels.mapValues { ObjectIdentifier($0) }
                let selectedTabs = order.map { controller.selectedTab(inPane: $0)?.id }
                let sequence = workspace.debugTilingActionCountForTesting

                let shortcutEvent: NSEvent
                if useDefault {
                    let shortcut = shortcutAction.defaultShortcut
                    let keys: [String: (String, UInt16)] = [
                        "t": ("t", 17), "m": ("m", 46), "l": ("l", 37), "0": ("0", 29),
                        "\r": ("\r", 36), "←": ("\u{f702}", 123), "→": ("\u{f703}", 124),
                        "↑": ("\u{f700}", 126), "↓": ("\u{f701}", 125)
                    ]
                    let key = try #require(keys[shortcut.key])
                    shortcutEvent = try event(window, key: key.0, keyCode: key.1, modifiers: shortcut.modifierFlags)
                } else {
                    shortcutEvent = try event(window)
                }
                #expect(app.debugHandleShortcutMonitorEvent(event: shortcutEvent))

                #expect(workspace.debugTilingActionCountForTesting == sequence + 1)
                #expect(workspace.debugLastTilingActionForTesting == action)
                #expect(Set(controller.allPaneIds) == Set(order))
                #expect(Set(controller.allTabIds) == tabs)
                #expect(workspace.panels.mapValues { ObjectIdentifier($0) } == panels)
                #expect(order.map { controller.selectedTab(inPane: $0)?.id } == selectedTabs)
                switch action {
                case .tile:
                    #expect(controller.tilingLayout == .tile)
                    #expect(controller.zoomedPaneId == nil)
                case .monocle, .toggleLayout:
                    #expect(controller.tilingLayout == .monocle)
                    #expect(controller.zoomedPaneId == order[1])
                case .focusNext:
                    #expect(controller.focusedPaneId == order[2])
                case .focusPrevious:
                    #expect(controller.focusedPaneId == order[0])
                case .moveNext:
                    #expect(controller.allPaneIds == [order[0], order[2], order[1]])
                    #expect(controller.focusedPaneId == order[1])
                case .movePrevious, .promote:
                    #expect(controller.allPaneIds == [order[1], order[0], order[2]])
                    #expect(controller.focusedPaneId == order[1])
                case .increaseMasterCount:
                    #expect(controller.masterCount == 2)
                case .decreaseMasterCount:
                    #expect(controller.masterCount == 0)
                case .increaseMasterRatio:
                    #expect(abs(controller.masterRatio - 0.6) < 0.000_001)
                case .decreaseMasterRatio:
                    #expect(abs(controller.masterRatio - 0.5) < 0.000_001)
                case .manual:
                    #expect(controller.tilingLayout == .manual)
                    #expect(controller.zoomedPaneId == nil)
                    #expect(controller.layoutSnapshot().panes == manualPanes)
                }
            }
        }
    }

    @Test
    func fileReloadInvalidatesUnboundAndRemappedShortcutCache() throws {
        try withEnvironment { app, configURL in
            try withWorkspace(app) { window, _, workspace in
                let initialSequence = workspace.debugTilingActionCountForTesting
                // Populate the empty cache before a binding appears.
                let unboundEvent = try event(window)
                #expect(!app.debugHandleCustomShortcut(event: unboundEvent))
                #expect(workspace.debugTilingActionCountForTesting == initialSequence)
                try configure(configURL, bindings: ["tilingMonocle": "cmd+ctrl+opt+t"])
                let newlyBoundEvent = try event(window)
                #expect(app.debugHandleCustomShortcut(event: newlyBoundEvent))
                #expect(workspace.bonsplitController.tilingLayout == .monocle)

                try configure(configURL, bindings: ["tilingMonocle": "cmd+ctrl+opt+y"])
                #expect(workspace.performTilingAction(.tile))
                let beforeRemapped = workspace.debugTilingActionCountForTesting
                let oldBindingEvent = try event(window)
                #expect(!app.debugHandleCustomShortcut(event: oldBindingEvent))
                #expect(workspace.debugTilingActionCountForTesting == beforeRemapped)
                let remappedEvent = try event(window, key: "y", keyCode: 16)
                #expect(app.debugHandleCustomShortcut(event: remappedEvent))
                #expect(workspace.debugTilingActionCountForTesting == beforeRemapped + 1)
                #expect(workspace.bonsplitController.tilingLayout == .monocle)

                try configure(configURL, bindings: [:])
                let beforeUnbound = workspace.debugTilingActionCountForTesting
                let clearedEvent = try event(window, key: "y", keyCode: 16)
                #expect(!app.debugHandleCustomShortcut(event: clearedEvent))
                #expect(workspace.debugTilingActionCountForTesting == beforeUnbound)
            }
        }
    }

    @Test
    func configuredWhenClauseUsesLiveWindowContextAndReloadedPredicate() throws {
        try withEnvironment { app, configURL in
            try configure(configURL, bindings: ["tilingMonocle": "cmd+ctrl+opt+t"], when: ["tilingMonocle": "paneCount >= 4"])
            try withWorkspace(app) { window, _, workspace in
                #expect(KeyboardShortcutSettings.menuShortcut(for: .tilingMonocle).isUnbound)
                let initialSequence = workspace.debugTilingActionCountForTesting
                let deniedEvent = try event(window)
                #expect(!app.debugHandleCustomShortcut(event: deniedEvent))
                #expect(workspace.debugTilingActionCountForTesting == initialSequence)

                let panelID = try #require(workspace.focusedPanelId)
                _ = try #require(workspace.newTerminalSplit(
                    from: panelID, orientation: .vertical, focus: false, initialCommand: "/usr/bin/true"
                ))
                let allowedEvent = try event(window)
                #expect(app.debugHandleCustomShortcut(event: allowedEvent))
                #expect(workspace.bonsplitController.tilingLayout == .monocle)

                try configure(configURL, bindings: ["tilingMonocle": "cmd+ctrl+opt+t"], when: ["tilingMonocle": "paneCount == 3"])
                #expect(workspace.performTilingAction(.tile))
                let beforeDenied = workspace.debugTilingActionCountForTesting
                let changedPredicateEvent = try event(window)
                #expect(!app.debugHandleCustomShortcut(event: changedPredicateEvent))
                #expect(workspace.debugTilingActionCountForTesting == beforeDenied)
                #expect(workspace.bonsplitController.tilingLayout == .tile)
            }
        }
    }

    @Test
    func explicitEventWindowWinsOverAnotherActiveManager() throws {
        try withEnvironment { app, configURL in
            try configure(configURL, bindings: ["tilingMonocle": "cmd+ctrl+opt+t"])
            try withWorkspace(app) { targetWindow, _, targetWorkspace in
                try withWorkspace(app) { _, otherManager, otherWorkspace in
                    app.tabManager = otherManager
                    let otherSequence = otherWorkspace.debugTilingActionCountForTesting
                    let targetSequence = targetWorkspace.debugTilingActionCountForTesting
                    let targetEvent = try event(targetWindow)
                    #expect(app.debugHandleCustomShortcut(event: targetEvent))
                    #expect(targetWorkspace.debugTilingActionCountForTesting == targetSequence + 1)
                    #expect(targetWorkspace.bonsplitController.tilingLayout == .monocle)
                    #expect(otherWorkspace.debugTilingActionCountForTesting == otherSequence)
                    #expect(otherWorkspace.bonsplitController.tilingLayout == .manual)
                }
            }
        }
    }

    @Test
    func chordWaitsForSecondStrokeAndDoesNotCrossWindows() throws {
        try withEnvironment { app, configURL in
            try configure(configURL, bindings: ["tilingMonocle": ["cmd+ctrl+opt+t", "m"]])
            try withWorkspace(app) { firstWindow, _, firstWorkspace in
                try withWorkspace(app) { secondWindow, _, secondWorkspace in
                    let before = firstWorkspace.debugTilingActionCountForTesting
                    let prefixEvent = try event(firstWindow)
                    #expect(app.debugHandleCustomShortcut(event: prefixEvent))
                    #expect(firstWorkspace.debugTilingActionCountForTesting == before)
                    let wrongWindowEvent = try event(secondWindow, key: "m", keyCode: 46, modifiers: [])
                    #expect(!app.debugHandleCustomShortcut(event: wrongWindowEvent))
                    #expect(secondWorkspace.bonsplitController.tilingLayout == .manual)
                    #expect(firstWorkspace.bonsplitController.tilingLayout == .manual)

                    let secondPrefixEvent = try event(firstWindow)
                    let completionEvent = try event(firstWindow, key: "m", keyCode: 46, modifiers: [])
                    #expect(app.debugHandleCustomShortcut(event: secondPrefixEvent))
                    #expect(app.debugHandleCustomShortcut(event: completionEvent))
                    #expect(firstWorkspace.debugTilingActionCountForTesting == before + 1)
                    #expect(firstWorkspace.bonsplitController.tilingLayout == .monocle)
                }
            }
        }
    }

    @Test
    func legacyZoomShortcutRoundTripsActiveTilingAndPreservesFocus() throws {
        try withEnvironment { app, configURL in
            try configure(configURL, bindings: ["toggleSplitZoom": "cmd+shift+enter"])
            try withWorkspace(app) { window, _, workspace in
                #expect(workspace.performTilingAction(.tile))
                let controller = workspace.bonsplitController
                let focusedPane = try #require(controller.allPaneIds.last)
                controller.focusPane(focusedPane)
                let focusedPanel = workspace.focusedPanelId
                let tabs = Set(controller.allTabIds)
                for expectedLayout in [PaneTilingLayout.monocle, .tile] {
                    let zoomEvent = try event(window, key: "\r", keyCode: 36, modifiers: [.command, .shift])
                    #expect(app.debugHandleShortcutMonitorEvent(event: zoomEvent))
                    #expect(controller.tilingLayout == expectedLayout)
                    #expect(controller.zoomedPaneId == (expectedLayout == .monocle ? focusedPane : nil))
                    #expect(controller.focusedPaneId == focusedPane)
                    #expect(workspace.focusedPanelId == focusedPanel)
                    #expect(Set(controller.allTabIds) == tabs)
                }
            }
        }
    }

    private func withEnvironment(_ body: (AppDelegate, URL) throws -> Void) throws {
        let previousApp = AppDelegate.shared
        let previousStore = KeyboardShortcutSettings.settingsFileStore
        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-tiling-shortcuts-\(UUID().uuidString).json")
        // All bindings are file-managed, so neither persisted user shortcuts nor defaults leak in.
        try writeConfiguration(configURL, bindings: [:], when: [:])
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.settingsFileStore = store
        let app = AppDelegate()
        defer {
            app.debugResetShortcutRoutingStateForTesting()
            KeyboardShortcutSettings.settingsFileStore = previousStore
            AppDelegate.shared = previousApp
            try? FileManager.default.removeItem(at: configURL)
        }
        try body(app, configURL)
    }

    private func configure(_ url: URL, bindings: [String: Any], when: [String: String] = [:]) throws {
        try writeConfiguration(url, bindings: bindings, when: when)
        // Exercise the same parser and notification that the real file watcher calls.
        KeyboardShortcutSettings.settingsFileStore.reload()
    }

    private func writeConfiguration(_ url: URL, bindings: [String: Any], when: [String: String]) throws {
        var allBindings = Dictionary(uniqueKeysWithValues: KeyboardShortcutSettings.Action.allCases.map { ($0.rawValue, NSNull() as Any) })
        allBindings.merge(bindings) { _, replacement in replacement }
        let payload: [String: Any] = ["schemaVersion": 1, "shortcuts": ["bindings": allBindings, "when": when]]
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    private func withWorkspace(_ app: AppDelegate, _ body: (NSWindow, TabManager, Workspace) throws -> Void) throws {
        let manager = TabManager(initialWorkingDirectory: "/private/tmp", autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        _ = workspace.performTilingAction(.manual)
        workspace.debugTracksTilingActionsForTesting = true
        workspace.setPortalRenderingEnabled(false, reason: "test.tilingShortcut")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let windowID = UUID()
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
        app.registerMainWindowContextForTesting(windowId: windowID, tabManager: manager)
        // Resolve the real window context without ordering the window front or posting events.
        _ = try #require(app.contextForMainTerminalWindow(window))
        app.tabManager = manager
        defer {
            workspace.setPortalRenderingEnabled(false, reason: "test.tilingShortcut.cleanup")
            for panel in workspace.panels.values { panel.close() }
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            window.close()
        }
        let first = try #require(workspace.focusedPanelId)
        let second = try #require(workspace.newTerminalSplit(
            from: first, orientation: .horizontal, focus: false, initialCommand: "/usr/bin/true", initialDividerPosition: 0.7
        ))
        _ = try #require(workspace.newTerminalSplit(
            from: second.id, orientation: .vertical, focus: false, initialCommand: "/usr/bin/true", initialDividerPosition: 0.3
        ))
        workspace.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 800))
        try body(window, manager, workspace)
    }

    private func event(_ window: NSWindow, key: String = "t", keyCode: UInt16 = 17, modifiers: NSEvent.ModifierFlags = [.command, .control, .option]) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode
        ))
    }
}
