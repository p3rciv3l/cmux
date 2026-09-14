import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises native geometry and lifecycle through the real portal scheduling entrypoints.
@Suite(.serialized)
@MainActor
struct TerminalPortalExternalGeometryTests {
    @Test(arguments: Scope.allCases)
    func ordinaryRequestIncludesLaterQueuedAncestorMovement(scope: Scope) async throws {
        let fixture = try await makeFixture()
        defer { close(fixture) }
        let original = fixture.anchor.convert(fixture.anchor.bounds, to: nil)

        scope.schedule(in: fixture.window)
        await onNextMainQueueEvent {
            fixture.container.frame.origin.x += 96
            fixture.root.layoutSubtreeIfNeeded()
        }
        await finishQueuedEvents()

        expectMatchingGeometry(fixture)
        expectMovedHitRegions(fixture, original: original)
    }

    @Test(arguments: Scope.allCases, Urgency.allCases)
    func committedGeometryIsDeliveredOnFirstQueuedEvent(scope: Scope, urgency: Urgency) async throws {
        let fixture = try await makeFixture()
        defer { close(fixture) }
        if urgency == .interactive {
            TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
        }
        defer {
            if urgency == .interactive {
                TerminalWindowPortalRegistry.endInteractiveGeometryResize()
            }
        }
        fixture.container.frame.origin.x += 96
        fixture.root.layoutSubtreeIfNeeded()
        scope.schedule(in: fixture.window, forceImmediate: urgency == .explicit)

        let firstGeometry = await onNextMainQueueEvent {
            geometrySnapshot(fixture)
        }
        expectMatchingGeometry(firstGeometry)
        await finishQueuedEvents()
        #expect(geometrySnapshot(fixture).actual == firstGeometry.actual)
        let settledCounts = TerminalWindowPortalRegistry.debugOperationCounts(in: fixture.window)
        await finishQueuedEvents()
        #expect(TerminalWindowPortalRegistry.debugOperationCounts(in: fixture.window) == settledCounts)
    }

    @Test(arguments: Scope.allCases, [false, true])
    func urgentBatchAlsoHonorsItsDeferredLayoutRequest(scope: Scope, urgentFirst: Bool) async throws {
        let fixture = try await makeFixture()
        defer { close(fixture) }
        fixture.container.frame.origin.x += 48
        fixture.root.layoutSubtreeIfNeeded()

        scope.schedule(in: fixture.window, forceImmediate: urgentFirst)
        scope.schedule(in: fixture.window, forceImmediate: !urgentFirst)
        let firstGeometry = await onNextMainQueueEvent {
            // Urgent delivery cannot be postponed by an earlier ordinary request.
            let geometry = geometrySnapshot(fixture)
            fixture.container.frame.origin.x += 96
            fixture.root.layoutSubtreeIfNeeded()
            return geometry
        }
        expectMatchingGeometry(firstGeometry)
        await finishQueuedEvents()

        // Promoting the batch must not consume the ordinary request before its queued layout.
        expectMatchingGeometry(fixture)
        let settledCounts = TerminalWindowPortalRegistry.debugOperationCounts(in: fixture.window)
        await finishQueuedEvents()
        #expect(TerminalWindowPortalRegistry.debugOperationCounts(in: fixture.window) == settledCounts)
    }

    @Test(arguments: Scope.allCases)
    func ordinaryBurstCoalescesAndStopsWhenGeometryStops(scope: Scope) async throws {
        let fixture = try await makeFixture()
        defer { close(fixture) }
        let before = try #require(TerminalWindowPortalRegistry.debugOperationCounts(in: fixture.window))
        for _ in 0..<24 {
            fixture.container.frame.origin.x += 2
            scope.schedule(in: fixture.window, forceImmediate: false)
        }
        await finishQueuedEvents()

        expectMatchingGeometry(fixture)
        let settled = try #require(TerminalWindowPortalRegistry.debugOperationCounts(in: fixture.window))
        #expect(settled["frame_changes", default: 0] - before["frame_changes", default: 0] == 1)
        await finishQueuedEvents()
        #expect(TerminalWindowPortalRegistry.debugOperationCounts(in: fixture.window) == settled)
    }

    @Test(arguments: [false, true])
    func transientAnchorLossHidesButRetainsAndRebindsTheSameTerminal(releaseAnchor: Bool) async throws {
        let fixture = try await makeFixture()
        defer { close(fixture) }
        let hosted = fixture.surface.hostedView
        let nativeParent = try #require(hosted.superview)
        var retiredAnchor: NSView? = NSView(frame: fixture.anchor.frame)
        fixture.container.addSubview(retiredAnchor!)
        bind(fixture.surface, to: retiredAnchor!)
        let oldPoint = retiredAnchor!.convert(NSPoint(x: 100, y: 90), to: nil)
        retiredAnchor!.removeFromSuperview()
        if releaseAnchor { retiredAnchor = nil }

        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: fixture.window)
        await finishQueuedEvents()
        #expect(hosted.isHidden)
        #expect(hosted.superview === nativeParent)
        #expect(TerminalWindowPortalRegistry.debugAnchorView(for: hosted) === retiredAnchor)
        #expect(TerminalWindowPortalRegistry.terminalViewAtWindowPoint(oldPoint, in: fixture.window) == nil)
        #expect(nativeParent.subviews.compactMap { $0 as? GhosttySurfaceScrollView }.count == 1)

        let replacement = NSView(frame: NSRect(x: 380, y: 70, width: 240, height: 210))
        fixture.root.addSubview(replacement)
        bind(fixture.surface, to: replacement)
        await finishQueuedEvents()
        #expect(TerminalWindowPortalRegistry.debugAnchorView(for: hosted) === replacement)
        #expect(hosted.superview === nativeParent)
        #expect(!hosted.isHidden)
        #expect(nativeParent.subviews.compactMap { $0 as? GhosttySurfaceScrollView }.count == 1)
        expectMatchingGeometry(hosted: hosted, anchor: replacement)
        let newPoint = replacement.convert(NSPoint(x: 120, y: 100), to: nil)
        #expect(TerminalWindowPortalRegistry.terminalViewAtWindowPoint(newPoint, in: fixture.window) != nil)
        #expect(TerminalWindowPortalRegistry.terminalViewAtWindowPoint(oldPoint, in: fixture.window) == nil)
    }

    @Test
    func hiddenEntryWithMissingAnchorIsPruned() async throws {
        let fixture = try await makeFixture()
        defer { close(fixture) }
        let hosted = fixture.surface.hostedView
        TerminalWindowPortalRegistry.hideHostedView(hosted)
        fixture.anchor.removeFromSuperview()

        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: fixture.window)
        await finishQueuedEvents()
        #expect(hosted.superview == nil)
        #expect(TerminalWindowPortalRegistry.debugAnchorView(for: hosted) == nil)
    }

    @Test(arguments: [false, true])
    func realPanelCloseDisposesAnchoredAndTransientlyDetachedTerminals(anchorDetached: Bool) async throws {
        let fixture = try await makeFixture()
        defer { close(fixture) }
        let hosted = fixture.surface.hostedView
        let nativeParent = try #require(hosted.superview)
        if anchorDetached { fixture.anchor.removeFromSuperview() }
        let panel = TerminalPanel(workspaceId: fixture.surface.tabId, surface: fixture.surface)

        panel.close()
        #expect(hosted.superview == nil)
        #expect(TerminalWindowPortalRegistry.debugAnchorView(for: hosted) == nil)
        #expect(nativeParent.subviews.compactMap { $0 as? GhosttySurfaceScrollView }.isEmpty)
        await finishQueuedEvents()
        #expect(hosted.superview == nil)
        #expect(TerminalWindowPortalRegistry.debugAnchorView(for: hosted) == nil)
    }

    enum Scope: CaseIterable {
        case window
        case allWindows

        @MainActor
        func schedule(in window: NSWindow, forceImmediate: Bool? = nil) {
            switch (self, forceImmediate) {
            case (.window, .none):
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
            case (.window, .some(let immediate)):
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window, forceImmediate: immediate)
            case (.allWindows, .none):
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
            case (.allWindows, .some(let immediate)):
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows(forceImmediate: immediate)
            }
        }
    }

    enum Urgency: CaseIterable {
        case explicit
        case interactive
    }

    private typealias Fixture = (
        window: NSWindow,
        root: NSView,
        container: NSView,
        anchor: NSView,
        surface: TerminalSurface
    )

    private func makeFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        var created = false
        defer { if !created { closeWindow(window) } }
        let root = try #require(window.contentView)
        let container = NSView(frame: NSRect(x: 30, y: 40, width: 220, height: 180))
        let anchor = NSView(frame: container.bounds)
        root.addSubview(container)
        container.addSubview(anchor)
        var config = CmuxSurfaceConfigTemplate()
        config.waitAfterCommand = true
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: config,
            initialCommand: "/usr/bin/true"
        )
        defer { if !created { surface.teardownSurface() } }
        bind(surface, to: anchor)
        await finishQueuedEvents()
        try #require(surface.hostedView.window === window)
        try #require(!surface.hostedView.isHidden)
        created = true
        return (window, root, container, anchor, surface)
    }

    private func bind(_ surface: TerminalSurface, to anchor: NSView) {
        TerminalWindowPortalRegistry.bind(
            hostedView: surface.hostedView,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
    }

    private func expectMatchingGeometry(_ fixture: Fixture) {
        expectMatchingGeometry(geometrySnapshot(fixture))
    }

    private func expectMatchingGeometry(hosted: NSView, anchor: NSView) {
        expectMatchingGeometry((hosted.convert(hosted.bounds, to: nil), anchor.convert(anchor.bounds, to: nil)))
    }

    private func geometrySnapshot(_ fixture: Fixture) -> (actual: NSRect, expected: NSRect) {
        (
            fixture.surface.hostedView.convert(fixture.surface.hostedView.bounds, to: nil),
            fixture.anchor.convert(fixture.anchor.bounds, to: nil)
        )
    }

    private func expectMatchingGeometry(_ geometry: (actual: NSRect, expected: NSRect)) {
        let (actual, expected) = geometry
        #expect(abs(actual.minX - expected.minX) <= 0.5)
        #expect(abs(actual.minY - expected.minY) <= 0.5)
        #expect(abs(actual.width - expected.width) <= 0.5)
        #expect(abs(actual.height - expected.height) <= 0.5)
    }

    private func expectMovedHitRegions(_ fixture: Fixture, original: NSRect) {
        let moved = fixture.anchor.convert(fixture.anchor.bounds, to: nil)
        let retired = NSPoint(x: (original.minX + moved.minX) / 2, y: moved.midY)
        let entered = NSPoint(x: (original.maxX + moved.maxX) / 2, y: moved.midY)
        #expect(TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retired, in: fixture.window) == nil)
        #expect(TerminalWindowPortalRegistry.terminalViewAtWindowPoint(entered, in: fixture.window) != nil)
    }

    // Observe the actual dispatch event source: Task.yield does not establish FIFO order with queued AppKit layout.
    private func onNextMainQueueEvent<Value: Sendable>(_ body: @escaping @MainActor () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: body())
            }
        }
    }

    private func finishQueuedEvents() async {
        // A bounded chain of delivery acknowledgements, not a timer or a readiness poll.
        for _ in 0..<8 { await onNextMainQueueEvent {} }
    }

    private func close(_ fixture: Fixture) {
        TerminalWindowPortalRegistry.detach(hostedView: fixture.surface.hostedView)
        fixture.surface.teardownSurface()
        closeWindow(fixture.window)
    }

    private func closeWindow(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        window.orderOut(nil)
        window.close()
    }
}
