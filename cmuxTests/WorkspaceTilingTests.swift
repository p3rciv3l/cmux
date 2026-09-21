import AppKit
import Bonsplit
import Combine
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises the app's shared action path with unmounted, local terminal panels.
/// Native first-responder delivery needs tagged app dogfood.
@Suite(.serialized)
@MainActor
struct WorkspaceTilingTests {
    @Test
    func newWorkspacePreservesDirectionalSplits() throws {
        let workspace = Workspace(initialTerminalCommand: "/usr/bin/true")
        defer { dispose(workspace) }
        let controller = workspace.bonsplitController
        #expect(controller.tilingLayout == .manual)
        let original = try #require(workspace.focusedPanelId)
        let added = try #require(workspace.newTerminalSplit(
            from: original, orientation: .vertical, focus: false, initialCommand: "/usr/bin/true"
        ))
        #expect(controller.allPaneIds.first == workspace.paneId(forPanelId: original))
        #expect(controller.allPaneIds.last == workspace.paneId(forPanelId: added.id))
        #expect(controller.tilingLayout == .manual)
        #expect(controller.masterCount == 1)
        #expect(controller.masterRatio == 0.55)
    }

    @Test(arguments: [false, true])
    func manualLayoutSurvivesRestoreRegardlessOfLegacyMarker(legacy: Bool) throws {
        let workspace = try fixture()
        defer { dispose(workspace) }
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.tiling?.layout == .manual)
        snapshot.tilingDefaultsVersion = legacy ? nil : 1
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: encoded)
        let restored = Workspace(initialTerminalCommand: "/usr/bin/true")
        defer { dispose(restored) }
        _ = restored.restoreSessionSnapshot(decoded)
        #expect(restored.bonsplitController.tilingLayout == .manual)
        #expect(restored.panels.count == workspace.panels.count)
        #expect(restored.sessionSnapshot(includeScrollback: false).tilingDefaultsVersion == 1)
    }

    @Test(arguments: PaneTilingAction.allCases)
    func everyActionPreservesTerminalPanelsSurfacesAndTabs(action: PaneTilingAction) throws {
        let workspace = try fixture()
        defer { dispose(workspace) }
        if action != .tile {
            #expect(workspace.performTilingAction(.tile))
        }
        if action == .promote {
            workspace.bonsplitController.focusPane(try #require(workspace.bonsplitController.allPaneIds.last))
        }

        let controller = workspace.bonsplitController
        let paneIDs = Set(controller.allPaneIds)
        let tabIDs = Set(controller.allTabIds)
        let panelIDs = Set(workspace.panels.keys)
        let terminals = workspace.panels.values.compactMap { $0 as? TerminalPanel }
        let identities = try terminals.map { panel in
            let paneID = try #require(workspace.paneId(forPanelId: panel.id))
            return (
                panel: panel,
                surface: panel.surface,
                runtime: panel.surface.surface,
                hostedView: panel.hostedView,
                paneID: paneID,
                tabID: try #require(workspace.surfaceIdFromPanelId(panel.id)),
                paneTabIDs: controller.tabs(inPane: paneID).map(\.id),
                selectedTabID: controller.selectedTab(inPane: paneID)?.id
            )
        }

        #expect(workspace.performTilingAction(action))

        #expect(Set(controller.allPaneIds) == paneIDs)
        #expect(Set(controller.allTabIds) == tabIDs)
        #expect(Set(workspace.panels.keys) == panelIDs)
        for identity in identities {
            let panel = try #require(workspace.terminalPanel(for: identity.panel.id))
            #expect(panel === identity.panel)
            #expect(panel.surface === identity.surface)
            #expect(panel.surface.surface == identity.runtime)
            #expect(panel.hostedView === identity.hostedView)
            #expect(workspace.paneId(forPanelId: panel.id) == identity.paneID)
            #expect(workspace.surfaceIdFromPanelId(panel.id) == identity.tabID)
            #expect(workspace.panelIdFromSurfaceId(identity.tabID) == panel.id)
            #expect(controller.tabs(inPane: identity.paneID).map(\.id) == identity.paneTabIDs)
            #expect(controller.selectedTab(inPane: identity.paneID)?.id == identity.selectedTabID)
        }
    }

    @Test
    func monocleFocusNavigationWrapsAndKeepsEachPanesSelectedTerminal() throws {
        let workspace = try fixture()
        defer { dispose(workspace) }
        let controller = workspace.bonsplitController
        let panes = controller.allPaneIds
        let firstPane = try #require(panes.first)
        controller.focusPane(firstPane)
        let selectedPanels = try panes.map { pane in
            let tab = try #require(controller.selectedTab(inPane: pane))
            return try #require(workspace.panelIdFromSurfaceId(tab.id))
        }

        #expect(workspace.performTilingAction(.monocle))
        for offset in 1...panes.count {
            #expect(workspace.performTilingAction(.focusNext))
            let index = offset % panes.count
            #expect(controller.focusedPaneId == panes[index])
            #expect(controller.zoomedPaneId == panes[index])
            #expect(workspace.focusedPanelId == selectedPanels[index])
        }
        #expect(workspace.performTilingAction(.focusPrevious))
        #expect(controller.focusedPaneId == panes.last)
        #expect(controller.zoomedPaneId == panes.last)
        #expect(workspace.focusedPanelId == selectedPanels.last)
    }

    @Test
    func promotionMovesWholePaneAndRetainsTheSelectedTerminal() throws {
        let workspace = try fixture()
        defer { dispose(workspace) }
        let controller = workspace.bonsplitController
        #expect(workspace.performTilingAction(.tile))
        let promotedPane = try #require(controller.allPaneIds.last)
        controller.focusPane(promotedPane)
        let focusedPanel = try #require(workspace.focusedPanelId)
        let originalTabs = controller.tabs(inPane: promotedPane).map(\.id)

        #expect(workspace.performTilingAction(.promote))

        #expect(controller.allPaneIds.first == promotedPane)
        #expect(controller.focusedPaneId == promotedPane)
        #expect(workspace.focusedPanelId == focusedPanel)
        #expect(controller.tabs(inPane: promotedPane).map(\.id) == originalTabs)
    }

    @Test
    func manualRestoresOriginalSplitGeometryAfterReorderingAndResizing() throws {
        let workspace = try fixture()
        defer { dispose(workspace) }
        let controller = workspace.bonsplitController
        let originalPanes = controller.layoutSnapshot().panes

        #expect(workspace.performTilingAction(.tile))
        #expect(workspace.performTilingAction(.moveNext))
        #expect(workspace.performTilingAction(.increaseMasterCount))
        #expect(workspace.performTilingAction(.decreaseMasterRatio))
        #expect(workspace.performTilingAction(.manual))

        #expect(controller.tilingLayout == .manual)
        #expect(controller.zoomedPaneId == nil)
        #expect(controller.layoutSnapshot().panes == originalPanes)
    }

    @Test
    func splitAndCloseWhileTiledKeepSurvivingTerminalsAndLayoutUsable() throws {
        let workspace = try fixture()
        defer { dispose(workspace) }
        let controller = workspace.bonsplitController
        let originalIDs = Set(workspace.panels.keys)
        let sourcePanel = try #require(workspace.focusedPanelId)
        let originalSurface = try #require(workspace.terminalPanel(for: sourcePanel)).surface
        #expect(workspace.performTilingAction(.tile))

        let addedPanel = try #require(workspace.newTerminalSplit(
            from: sourcePanel,
            orientation: .vertical,
            focus: false,
            initialCommand: "/usr/bin/true"
        ))
        let addedPane = try #require(workspace.paneId(forPanelId: addedPanel.id))
        #expect(controller.allPaneIds.first == addedPane)
        #expect(controller.tilingLayout == .tile)
        #expect(workspace.closePanel(addedPanel.id, force: true))

        #expect(Set(workspace.panels.keys) == originalIDs)
        #expect(!controller.allPaneIds.contains(addedPane))
        #expect(workspace.terminalPanel(for: sourcePanel)?.surface === originalSurface)
        #expect(workspace.performTilingAction(.monocle))
        #expect(workspace.performTilingAction(.focusNext))
        #expect(controller.zoomedPaneId == controller.focusedPaneId)
        #expect(workspace.performTilingAction(.manual))
        #expect(Set(workspace.panels.keys) == originalIDs)
    }

    @Test
    func sessionRoundTripPreservesPanesWithoutReenablingTiling() throws {
        let workspace = try fixture()
        defer { dispose(workspace) }
        let controller = workspace.bonsplitController
        #expect(workspace.performTilingAction(.tile))
        #expect(workspace.performTilingAction(.increaseMasterCount))
        #expect(workspace.performTilingAction(.decreaseMasterRatio))
        #expect(workspace.performTilingAction(.monocle))
        #expect(workspace.performTilingAction(.focusNext))
        let focusedPanel = try #require(workspace.focusedPanelId)
        let encoded = try JSONEncoder().encode(workspace.sessionSnapshot(includeScrollback: false))
        let snapshot = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: encoded)

        let restored = Workspace(initialTerminalCommand: "/usr/bin/true")
        restored.setPortalRenderingEnabled(false, reason: "test.workspaceTiling.restore")
        defer { dispose(restored) }
        let panelMapping = restored.restoreSessionSnapshot(snapshot)

        #expect(restored.bonsplitController.tilingLayout == .manual)
        #expect(restored.bonsplitController.allPaneIds.count == controller.allPaneIds.count)
        #expect(restored.panels.count == workspace.panels.count)
        #expect(restored.focusedPanelId == panelMapping[focusedPanel])
        #expect(restored.bonsplitController.zoomedPaneId == nil)
        #expect(restored.performTilingAction(.toggleLayout))
        #expect(restored.bonsplitController.tilingLayout == .tile)
    }

    @Test
    func repeatedGeometryCallbacksWithNewTimestampsDoNotRepublishWorkspace() throws {
        let workspace = try fixture()
        defer { dispose(workspace) }
        let controller = workspace.bonsplitController
        let initial = controller.layoutSnapshot()
        workspace.splitTabBar(controller, didChangeGeometry: initial)
        let publishedSnapshot = try #require(workspace.tmuxLayoutSnapshot)
        var publicationCount = 0
        let subscription = workspace.objectWillChange.sink { _ in publicationCount += 1 }
        defer { subscription.cancel() }

        // Nested native layout callbacks change the sampling time even when every
        // pane's geometry, tab selection and focus are already settled.
        for offset in 1...8 {
            workspace.splitTabBar(controller, didChangeGeometry: LayoutSnapshot(
                containerFrame: initial.containerFrame,
                panes: initial.panes,
                focusedPaneId: initial.focusedPaneId,
                timestamp: initial.timestamp + Double(offset)
            ))
        }

        #expect(publicationCount == 0)
        #expect(workspace.tmuxLayoutSnapshot == publishedSnapshot)

        let resized = LayoutSnapshot(
            containerFrame: PixelRect(x: 0, y: 0, width: 1500, height: 900),
            panes: initial.panes,
            focusedPaneId: initial.focusedPaneId,
            timestamp: initial.timestamp + 9
        )
        workspace.splitTabBar(controller, didChangeGeometry: resized)
        #expect(publicationCount == 1)
        #expect(workspace.tmuxLayoutSnapshot == resized)
    }

    @Test
    func repeatedPaneFocusDoesNotRepublishUnchangedSidebarMetadata() throws {
        let workspace = try fixture()
        defer { dispose(workspace) }
        let controller = workspace.bonsplitController
        let firstPane = try #require(controller.focusedPaneId)
        let firstPanel = try #require(workspace.focusedPanelId)
        let secondPane = try #require(controller.allPaneIds.first { $0 != firstPane })
        let secondTab = try #require(controller.selectedTab(inPane: secondPane))
        let secondPanel = try #require(workspace.panelIdFromSurfaceId(secondTab.id))
        workspace.updatePanelDirectory(panelId: firstPanel, directory: "/tmp/cmux-tiling-focus-first")
        workspace.updatePanelGitBranch(panelId: firstPanel, branch: "tiling-first", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: firstPanel,
            number: 1,
            label: "PR #1",
            url: try #require(URL(string: "https://example.invalid/pull/1")),
            status: .open,
            branch: "tiling-first"
        )
        workspace.updatePanelDirectory(panelId: secondPanel, directory: "/tmp/cmux-tiling-focus-second")
        workspace.updatePanelGitBranch(panelId: secondPanel, branch: "tiling-second", isDirty: true)
        workspace.splitTabBar(controller, didFocusPane: firstPane)

        var directoryPublications = 0
        var tabBarDirectoryPublications = 0
        var branchPublications = 0
        var pullRequestPublications = 0
        let subscriptions = [
            workspace.$currentDirectory.dropFirst().sink { _ in directoryPublications += 1 },
            workspace.$surfaceTabBarDirectory.dropFirst().sink { _ in tabBarDirectoryPublications += 1 },
            workspace.$gitBranch.dropFirst().sink { _ in branchPublications += 1 },
            workspace.$pullRequest.dropFirst().sink { _ in pullRequestPublications += 1 },
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        for _ in 0..<8 {
            workspace.splitTabBar(controller, didFocusPane: firstPane)
        }
        #expect(directoryPublications == 0)
        #expect(tabBarDirectoryPublications == 0)
        #expect(branchPublications == 0)
        #expect(pullRequestPublications == 0)

        controller.focusPane(secondPane)
        #expect(directoryPublications == 1)
        #expect(tabBarDirectoryPublications == 1)
        #expect(branchPublications == 1)
        #expect(pullRequestPublications == 1)
        #expect(workspace.currentDirectory == "/tmp/cmux-tiling-focus-second")
        #expect(workspace.surfaceTabBarDirectory == "/tmp/cmux-tiling-focus-second")
        #expect(workspace.gitBranch == SidebarGitBranchState(branch: "tiling-second", isDirty: true))
        #expect(workspace.pullRequest == nil)
    }

    @Test
    func portalRefreshWithoutAppKitFlushPreservesPendingSiblingLayoutAndRequestsRedraw() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = TilingLayoutCountingView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let sibling = TilingLayoutCountingView(frame: NSRect(x: 480, y: 0, width: 160, height: 400))
        window.contentView = root
        var config = CmuxSurfaceConfigTemplate()
        config.waitAfterCommand = true
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: config,
            initialCommand: "/usr/bin/true"
        )
        let hostedView = surface.hostedView
        hostedView.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        root.addSubview(hostedView)
        root.addSubview(sibling)
        defer {
            window.orderOut(nil)
            hostedView.removeFromSuperview()
            surface.teardownSurface()
            window.close()
        }
        window.orderBack(nil)
        hostedView.setVisibleInUI(true)
        window.displayIfNeeded()
        root.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        _ = hostedView.reconcileGeometryNow()
        let startupDeadline = ContinuousClock.now + .seconds(5)
        while surface.surface == nil && ContinuousClock.now < startupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(surface.surface, "The test must exercise a live Ghostty runtime surface")
        #expect(surface.uiWindow === window)
        window.displayIfNeeded()
        root.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        _ = hostedView.reconcileGeometryNow()

        root.layoutCount = 0
        sibling.layoutCount = 0
        root.needsLayout = true
        sibling.needsLayout = true
        surface.resetDebugForceRefreshCount()

        hostedView.refreshSurfaceNow(reason: "test.portal.noAppKitFlush", flushAppKitLayout: false)

        #expect(root.layoutCount == 0)
        #expect(sibling.layoutCount == 0)
        #expect(root.needsLayout)
        #expect(sibling.needsLayout)
        #expect(surface.debugForceRefreshCount() == 1)

        // Positive control: the default refresh must expose the ancestor/sibling
        // layout work caused by displayIfNeeded, so an unattached window cannot pass.
        root.layoutCount = 0
        sibling.layoutCount = 0
        root.needsLayout = true
        sibling.needsLayout = true
        surface.resetDebugForceRefreshCount()
        hostedView.refreshSurfaceNow(reason: "test.portal.defaultAppKitFlush")
        #expect(root.layoutCount > 0)
        #expect(sibling.layoutCount > 0)
        #expect(surface.debugForceRefreshCount() == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func terminalRevealWithoutAppKitFlushPreservesPendingAncestorAndSiblingLayout() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = TilingLayoutCountingView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let ancestor = TilingLayoutCountingView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        let sibling = TilingLayoutCountingView(frame: NSRect(x: 480, y: 0, width: 160, height: 400))
        let nestedSibling = TilingLayoutCountingView(frame: NSRect(x: 0, y: 0, width: 160, height: 200))
        window.contentView = root
        root.addSubview(ancestor)
        root.addSubview(sibling)
        sibling.addSubview(nestedSibling)
        var config = CmuxSurfaceConfigTemplate()
        config.waitAfterCommand = true
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: config,
            initialCommand: "/usr/bin/true"
        )
        let surfaceId = surface.id
        let ready = AsyncStream<UUID>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { notification in
            guard notification.userInfo?["surfaceId"] as? UUID == surfaceId else { return }
            ready.continuation.yield(surfaceId)
        }
        let hostedView = surface.hostedView
        hostedView.frame = ancestor.bounds
        ancestor.addSubview(hostedView)
        defer {
            NotificationCenter.default.removeObserver(readyObserver)
            ready.continuation.finish()
            window.orderOut(nil)
            hostedView.removeFromSuperview()
            surface.teardownSurface()
            window.close()
        }
        window.orderBack(nil)
        hostedView.setVisibleInUI(true)
        window.displayIfNeeded()
        root.layoutSubtreeIfNeeded()
        if surface.surface == nil {
            for await _ in ready.stream {
                if surface.surface != nil { break }
            }
        }
        _ = try #require(surface.surface, "The reveal must request redraw on a real Ghostty runtime")
        #expect(surface.uiWindow === window)
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        hostedView.setVisibleInUI(false)
        window.displayIfNeeded()
        root.layoutSubtreeIfNeeded()
        let unflushedViews = [root, ancestor, sibling, nestedSibling]
        for view in unflushedViews {
            view.layoutCount = 0
            view.needsLayout = true
        }
        surface.resetDebugForceRefreshCount()

        hostedView.setVisibleInUI(true, flushAppKitLayout: false)

        #expect(hostedView.debugPortalVisibleInUI)
        #expect(!hostedView.isHidden)
        for view in unflushedViews {
            #expect(view.layoutCount == 0)
            #expect(view.needsLayout)
        }
        #expect(surface.debugForceRefreshCount() == 1)

        // A redundant visibility update is not another reveal and must not draw.
        hostedView.setVisibleInUI(true, flushAppKitLayout: false)
        #expect(surface.debugForceRefreshCount() == 1)
        for view in unflushedViews {
            #expect(view.layoutCount == 0)
            #expect(view.needsLayout)
        }

        // Other callers keep the existing synchronous AppKit flush by default.
        hostedView.setVisibleInUI(false)
        for view in unflushedViews {
            view.layoutCount = 0
            view.needsLayout = true
        }
        surface.resetDebugForceRefreshCount()
        hostedView.setVisibleInUI(true)
        for view in unflushedViews {
            #expect(view.layoutCount > 0)
            #expect(!view.needsLayout)
        }
        #expect(surface.debugForceRefreshCount() == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [2, 3])
    func portalAnchorCallbacksSynchronizeEachPrimaryOnceAndCoalesceTheFailsafe(terminalCount: Int) async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        window.contentView = root
        var config = CmuxSurfaceConfigTemplate()
        config.waitAfterCommand = true
        let surfaces = (0..<terminalCount).map { _ in
            TerminalSurface(
                tabId: UUID(),
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                configTemplate: config,
                initialCommand: "/usr/bin/true"
            )
        }
        let anchors = (0..<terminalCount).map { index in
            NSView(frame: NSRect(x: CGFloat(20 + index * 280), y: 40, width: 220, height: 320))
        }
        let ownedSurfaceIDs = Set(surfaces.map(\.id))
        let ready = AsyncStream<UUID>.makeStream(bufferingPolicy: .bufferingNewest(terminalCount))
        // Register before native attachment so synchronously-created runtimes
        // and the asynchronous command-shim path use the same readiness signal.
        let readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { notification in
            guard let id = notification.userInfo?["surfaceId"] as? UUID,
                  ownedSurfaceIDs.contains(id) else { return }
            ready.continuation.yield(id)
        }
        let portal = WindowTerminalPortal(window: window)
        defer {
            NotificationCenter.default.removeObserver(readyObserver)
            ready.continuation.finish()
            window.orderOut(nil)
            portal.tearDown()
            surfaces.forEach { $0.teardownSurface() }
            window.close()
        }
        for (surface, anchor) in zip(surfaces, anchors) {
            root.addSubview(anchor)
            portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
            surface.hostedView.setVisibleInUI(true)
        }
        window.orderBack(nil)
        window.displayIfNeeded()
        root.layoutSubtreeIfNeeded()
        if surfaces.contains(where: { $0.surface == nil }) {
            for await _ in ready.stream {
                if surfaces.allSatisfy({ $0.surface != nil }) { break }
            }
        }
        for surface in surfaces {
            _ = try #require(surface.surface, "The test must exercise live Ghostty runtime surfaces")
            #expect(surface.uiWindow === window)
            surface.hostedView.layoutSubtreeIfNeeded()
            _ = surface.hostedView.reconcileGeometryNow()
        }
        // Drain the initial bind/layout deliveries before measuring this burst.
        // The portal schedules through the main queue; no time-based settling is used.
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        portal.resetDebugHostedViewSynchronizationCount()

        let hierarchyFlushesBeforeBurst = portal.debugHierarchySynchronizationCount

        for (surface, anchor) in zip(surfaces, anchors) {
            anchor.frame = anchor.frame.insetBy(dx: 12, dy: 8)
            portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)
            try expectPortalFrame(surface.hostedView, matching: anchor)
        }
        #expect(portal.debugHostedViewSynchronizationCount == terminalCount)
        #expect(portal.debugHierarchySynchronizationCount == hierarchyFlushesBeforeBurst)

        // No callback is delivered for this subsequent change. The single shared
        // failsafe must read its newest frame when the queued synchronization runs.
        let missedAnchor = try #require(anchors.last)
        let missedHostedView = try #require(surfaces.last).hostedView
        let previousHostedFrame = missedHostedView.frame
        missedAnchor.frame = missedAnchor.frame.insetBy(dx: 9, dy: 5)
        #expect(missedHostedView.frame == previousHostedFrame)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        try expectPortalFrame(missedHostedView, matching: missedAnchor)
        #expect(portal.debugHostedViewSynchronizationCount == terminalCount * 2)
        // A bulk pass shares one owning hierarchy flush, rather than flushing
        // the entire window again for each already-mounted terminal.
        #expect(portal.debugHierarchySynchronizationCount - hierarchyFlushesBeforeBurst == 1)

        // Interactive callers retain immediate all-entry reconciliation even if
        // only one anchor delivered a callback.
        for anchor in anchors { anchor.frame = anchor.frame.insetBy(dx: 3, dy: 2) }
        portal.resetDebugHostedViewSynchronizationCount()
        portal.synchronizeHostedViewForAnchor(try #require(anchors.first), syncLayout: true)
        #expect(portal.debugHostedViewSynchronizationCount == terminalCount)
        for (surface, anchor) in zip(surfaces, anchors) {
            try expectPortalFrame(surface.hostedView, matching: anchor)
        }

        // Divider/sidebar drag sessions keep the same immediate sibling repair
        // even when their representable callback opts out of ancestor layout.
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
        defer { TerminalWindowPortalRegistry.endInteractiveGeometryResize() }
        for anchor in anchors { anchor.frame = anchor.frame.insetBy(dx: 4, dy: 3) }
        portal.resetDebugHostedViewSynchronizationCount()
        portal.synchronizeHostedViewForAnchor(try #require(anchors.first), syncLayout: false)
        #expect(portal.debugHostedViewSynchronizationCount == terminalCount)
        for (surface, anchor) in zip(surfaces, anchors) {
            try expectPortalFrame(surface.hostedView, matching: anchor)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func portalGeometryRecoveryWakesAStalledWorkspaceWithoutAnotherWindowEvent() async throws {
        let workspace = Workspace(initialTerminalCommand: "/usr/bin/true")
        let panel = try #require(workspace.focusedPanelId.flatMap { workspace.terminalPanel(for: $0) })
        let hostedView = panel.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 600, height: 360))
        window.contentView = root
        root.addSubview(anchor)
        let ownedPanelId = panel.id
        let ready = AsyncStream<UUID>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { notification in
            guard notification.userInfo?["surfaceId"] as? UUID == ownedPanelId else { return }
            ready.continuation.yield(ownedPanelId)
        }
        let portal = WindowTerminalPortal(window: window)
        let completion = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer {
            workspace.debugLayoutFollowUpDidClearForTesting = nil
            completion.continuation.finish()
            NotificationCenter.default.removeObserver(readyObserver)
            ready.continuation.finish()
            window.orderOut(nil)
            portal.tearDown()
            dispose(workspace)
            window.close()
        }
        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: true)
        hostedView.setVisibleInUI(true)
        window.orderBack(nil)
        window.displayIfNeeded()
        root.layoutSubtreeIfNeeded()
        if panel.surface.surface == nil {
            for await _ in ready.stream {
                if panel.surface.surface != nil { break }
            }
        }
        _ = try #require(panel.surface.surface, "The recovery must exercise a real Ghostty surface")
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        try expectPortalFrame(hostedView, matching: anchor)

        workspace.scheduleTerminalGeometryReconcile()
        hostedView.frame = .zero
        workspace.debugAttemptEventDrivenLayoutFollowUpForTesting()

        let stalled = workspace.debugLayoutFollowUpStateForTesting()
        try #require(stalled.pending)
        try #require(stalled.geometryPending)
        try #require(!stalled.attemptScheduled)
        let flags = workspace.debugLayoutFollowUpPendingFlagsForTesting()
        #expect(flags.filter { $0.value }.map(\.key) == ["geometry"])

        // A different workspace's terminal cannot wake this workspace. This
        // delivery is synchronous, before any AppKit update/run-loop event.
        NotificationCenter.default.post(
            name: .terminalPortalGeometryDidBecomeReady,
            object: hostedView,
            userInfo: [GhosttyNotificationKey.surfaceId: UUID()]
        )
        #expect(!workspace.debugLayoutFollowUpStateForTesting().attemptScheduled)

        workspace.debugLayoutFollowUpDidClearForTesting = { reason in
            completion.continuation.yield(reason)
        }
        portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)
        try expectPortalFrame(hostedView, matching: anchor)
        // The formerly missing publisher must schedule the recovery immediately.
        // A later window update or timeout is not allowed to make this assertion pass.
        try #require(workspace.debugLayoutFollowUpStateForTesting().attemptScheduled)
        var completions = completion.stream.makeAsyncIterator()
        #expect(await completions.next() == "converged")
        #expect(!workspace.debugLayoutFollowUpStateForTesting().pending)
        #expect(!workspace.debugLayoutFollowUpStateForTesting().geometryPending)
        #expect(workspace.debugLayoutFollowUpPendingFlagsForTesting().values.allSatisfy { !$0 })
    }

    private func expectPortalFrame(_ hostedView: GhosttySurfaceScrollView, matching anchor: NSView) throws {
        let host = try #require(hostedView.superview)
        let expected = host.convert(anchor.bounds, from: anchor)
        #expect(abs(hostedView.frame.minX - expected.minX) <= 1)
        #expect(abs(hostedView.frame.minY - expected.minY) <= 1)
        #expect(abs(hostedView.frame.width - expected.width) <= 1)
        #expect(abs(hostedView.frame.height - expected.height) <= 1)
        #expect(!hostedView.isHidden)
    }

    @Test
    func geometryPublicationUpdatesObservableSnapshotWithoutRefreshingPaneContent() throws {
        let workspace = try fixture()
        defer { dispose(workspace) }
        let controller = workspace.bonsplitController
        workspace.splitTabBar(controller, didChangeGeometry: controller.layoutSnapshot())
        let revision = workspace.paneContentRevision
        var publications = 0
        let subscription = workspace.objectWillChange.sink { _ in publications += 1 }
        defer { subscription.cancel() }

        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        let resized = controller.layoutSnapshot()
        workspace.splitTabBar(controller, didChangeGeometry: resized)

        #expect(publications > 0)
        #expect(workspace.tmuxLayoutSnapshot == resized)
        #expect(workspace.paneContentRevision == revision)
    }

    @Test
    func paneReorderingPublishesSpatialOrderWithoutRefreshingPaneContent() throws {
        let workspace = try fixture()
        defer { dispose(workspace) }
        #expect(workspace.performTilingAction(.tile))
        let originalOrder = workspace.orderedPanelIds
        let originalLayoutVersion = workspace.paneLayoutVersion
        let revision = workspace.paneContentRevision
        var publications = 0
        let subscription = workspace.objectWillChange.sink { _ in publications += 1 }
        defer { subscription.cancel() }

        #expect(workspace.performTilingAction(.moveNext))

        #expect(workspace.orderedPanelIds != originalOrder)
        #expect(workspace.paneLayoutVersion > originalLayoutVersion)
        #expect(publications > 0)
        #expect(workspace.paneContentRevision == revision)
    }

    @Test
    func workspaceAndPanelPublicationsRefreshPaneContentButSharedIndexDoesNot() throws {
        let workspace = try fixture()
        defer { dispose(workspace) }
        let panelID = try #require(workspace.focusedPanelId)
        var revision = workspace.paneContentRevision

        workspace.customTitle = "Content revision workspace"
        #expect(workspace.paneContentRevision == revision + 1)
        revision = workspace.paneContentRevision
        workspace.setPanelCustomTitle(panelId: panelID, title: "Content revision terminal")
        #expect(workspace.paneContentRevision > revision)
        revision = workspace.paneContentRevision
        workspace.objectWillChange.send()
        #expect(workspace.paneContentRevision == revision + 1)
        revision = workspace.paneContentRevision
        SharedLiveAgentIndex.shared.objectWillChange.send()
        #expect(workspace.paneContentRevision == revision)
    }

    @Test
    func nestedContentPublicationDuringGeometryPublicationStillRefreshesPaneContent() throws {
        let workspace = try fixture()
        defer { dispose(workspace) }
        let controller = workspace.bonsplitController
        workspace.splitTabBar(controller, didChangeGeometry: controller.layoutSnapshot())
        let revision = workspace.paneContentRevision
        var didPublishNestedContent = false
        let subscription = workspace.objectWillChange.sink { _ in
            guard !didPublishNestedContent else { return }
            didPublishNestedContent = true
            workspace.customTitle = "Nested content publication"
        }
        defer { subscription.cancel() }

        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        let resized = controller.layoutSnapshot()
        workspace.splitTabBar(controller, didChangeGeometry: resized)

        #expect(didPublishNestedContent)
        #expect(workspace.customTitle == "Nested content publication")
        #expect(workspace.tmuxLayoutSnapshot == resized)
        #expect(workspace.paneContentRevision == revision + 1)
    }

    @Test(arguments: [false, true])
    func workspaceManualUnreadRepresentativeOnlyFollowsFocusWhenEnabled(isWorkspaceManuallyUnread: Bool) throws {
        let workspace = try fixture()
        defer { dispose(workspace) }
        let controller = workspace.bonsplitController
        controller.focusPane(try #require(controller.allPaneIds.first))
        let firstPanel = try #require(workspace.focusedPanelId)
        let before = WorkspaceContentView.workspaceManualUnreadRepresentative(
            workspace: workspace,
            isWorkspaceManuallyUnread: isWorkspaceManuallyUnread
        )
        #expect(before == (isWorkspaceManuallyUnread ? firstPanel : nil))

        #expect(workspace.performTilingAction(.focusNext))
        let nextPanel = try #require(workspace.focusedPanelId)
        #expect(nextPanel != firstPanel)
        let after = WorkspaceContentView.workspaceManualUnreadRepresentative(
            workspace: workspace,
            isWorkspaceManuallyUnread: isWorkspaceManuallyUnread
        )
        #expect(after == (isWorkspaceManuallyUnread ? nextPanel : nil))
        // This is the exact optional value included in the shared pane-content
        // revision: focus must not change it when no workspace unread ring exists.
        #expect((AnyHashable(before) == AnyHashable(after)) == !isWorkspaceManuallyUnread)

        let visibleUnreadPanels = Set(workspace.panels.keys.filter { panelId in
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                hasPanelUnreadIndicator: false,
                isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                isWorkspaceManualUnreadRepresentative: after == panelId
            )
        })
        #expect(visibleUnreadPanels == (isWorkspaceManuallyUnread ? Set([nextPanel]) : Set<UUID>()))
        #expect(!visibleUnreadPanels.contains(firstPanel))
    }

    @Test
    func selectedPanelFocusUsesLocalContextWithoutReadingGlobalFocus() {
        for isInputActive in [false, true] {
            for isSelected in [false, true] {
                for isGloballyFocused in [false, true] {
                    // Selected tabs agree with authoritative global focus once
                    // settled. Unselected content can remain globally focused
                    // transiently while its portal moves to another pane.
                    let isFocusedInPane = isSelected && isGloballyFocused
                    var globalFocusReads = 0
                    func readGlobalFocus() -> Bool {
                        globalFocusReads += 1
                        return isGloballyFocused
                    }
                    let focused = WorkspaceContentView.panelFocusedInUI(
                        isWorkspaceInputActive: isInputActive,
                        isSelectedInPane: isSelected,
                        isFocusedInPane: isFocusedInPane,
                        isGloballyFocused: readGlobalFocus()
                    )
                    #expect(focused == (isInputActive && isGloballyFocused))
                    #expect(globalFocusReads == (isInputActive && !isSelected ? 1 : 0))
                    #expect(WorkspaceContentView.panelVisibleInUI(
                        isWorkspaceVisible: true,
                        isSelectedInPane: isSelected,
                        isFocused: focused
                    ) == (isSelected || focused))
                }
            }
        }
    }

    private func fixture() throws -> Workspace {
        let workspace = Workspace(initialTerminalCommand: "/usr/bin/true")
        // These tests exercise switching away from a hand-built manual layout.
        _ = workspace.performTilingAction(.manual)
        workspace.setPortalRenderingEnabled(false, reason: "test.workspaceTiling")
        let firstPanel = try #require(workspace.focusedPanelId)
        let secondPanel = try #require(workspace.newTerminalSplit(
            from: firstPanel,
            orientation: .horizontal,
            focus: false,
            initialCommand: "/usr/bin/true",
            initialDividerPosition: 0.7
        ))
        let thirdPanel = try #require(workspace.newTerminalSplit(
            from: secondPanel.id,
            orientation: .vertical,
            focus: false,
            initialCommand: "/usr/bin/true",
            initialDividerPosition: 0.3
        ))
        let thirdPane = try #require(workspace.paneId(forPanelId: thirdPanel.id))
        _ = try #require(workspace.newTerminalSurface(
            inPane: thirdPane,
            focus: false,
            initialCommand: "/usr/bin/true"
        ))
        workspace.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 1440, height: 900))
        workspace.bonsplitController.focusPane(try #require(workspace.paneId(forPanelId: firstPanel)))
        return workspace
    }

    private func dispose(_ workspace: Workspace) {
        workspace.setPortalRenderingEnabled(false, reason: "test.workspaceTiling.cleanup")
        for panel in workspace.panels.values {
            panel.close()
        }
    }
}

@MainActor
private final class TilingLayoutCountingView: NSView {
    var layoutCount = 0

    override func layout() {
        layoutCount += 1
        super.layout()
    }
}
