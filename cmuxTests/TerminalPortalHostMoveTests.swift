import AppKit
import Bonsplit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises the real representable-installed callback and authoritative portal registry.
@Suite(.serialized)
@MainActor
struct TerminalPortalHostMoveTests {
    @Test(arguments: [false, true])
    func sameWindowNativeHandoffReusesBindingAndSynchronizesGeometry(changesSize: Bool) throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let hosted = fixture.surface.hostedView
        let portalHost = try #require(hosted.superview)
        let initialFrame = hosted.convert(hosted.bounds, to: nil)
        let initialCount = try bindingCount(fixture)
        #expect(fixture.window.makeFirstResponder(fixture.focusSentinel))

        if !changesSize {
            fixture.secondSlot.setFrameSize(fixture.hosting.frame.size)
        }

        fixture.secondSlot.addSubview(fixture.hosting)
        fixture.hosting.frame = fixture.secondSlot.bounds
        fixture.hosting.layoutSubtreeIfNeeded()
        let movedCount = try bindingCount(fixture)
        #expect(movedCount == initialCount)
        #expect(hosted.superview === portalHost)
        #expect(TerminalWindowPortalRegistry.isHostedView(hosted, boundTo: fixture.anchor))
        #expect(fixture.window.firstResponder === fixture.focusSentinel)
        #expect(!hosted.isHidden)
        #expect(hosted.convert(hosted.bounds, to: nil) != initialFrame)
        expectMatchingGeometry(fixture)

        // An AppKit callback with unchanged attachment must also be a no-op.
        fixture.anchor.viewDidMoveToWindow()
        let repeatedCount = try bindingCount(fixture)
        #expect(repeatedCount == movedCount)
        expectMatchingGeometry(fixture)
    }

    @Test(arguments: Recovery.allCases)
    func sameWindowCallbackRepairsStalePortalOwnership(recovery: Recovery) throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let hosted = fixture.surface.hostedView
        let portalHost = try #require(hosted.superview)
        let count = try bindingCount(fixture)
        switch recovery {
        case .missingRegistryEntry:
            TerminalWindowPortalRegistry.detach(hostedView: hosted)
        case .differentAnchor:
            TerminalWindowPortalRegistry.bind(
                hostedView: hosted,
                to: fixture.secondSlot,
                visibleInUI: true,
                expectedSurfaceId: fixture.surface.id,
                expectedGeneration: fixture.surface.portalBindingGeneration(),
                deferLayoutSynchronization: true
            )
        case .detachedHostedView:
            hosted.removeFromSuperview()
        case .wrongSameWindowParent:
            fixture.root.addSubview(hosted)
        case .differentTerminalHostInSameWindow:
            let otherHost = WindowTerminalHostView(frame: fixture.root.bounds)
            fixture.root.addSubview(otherHost)
            otherHost.addSubview(hosted)
        case .staleEntryVisibility:
            TerminalWindowPortalRegistry.hideHostedView(hosted)
        }

        fixture.anchor.viewDidMoveToWindow()
        TerminalWindowPortalRegistry.synchronizeForAnchor(fixture.anchor, syncLayout: false)
        let repairedCount = try bindingCount(fixture)
        #expect(repairedCount == count + 1)
        #expect(TerminalWindowPortalRegistry.isHostedView(hosted, boundTo: fixture.anchor))
        #expect(hosted.superview === portalHost)
        #expect(hosted.window === fixture.window)
        #expect(!hosted.isHidden)
        expectMatchingGeometry(fixture)
    }

    @Test
    func crossWindowMoveRebindsThenReusesTheNewWindowBinding() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let destination = makeWindow()
        defer { closeWindow(destination) }
        let destinationRoot = try #require(destination.contentView)
        let count = try bindingCount(fixture)

        destinationRoot.addSubview(fixture.hosting)
        fixture.hosting.frame = NSRect(x: 30, y: 40, width: 280, height: 230)
        fixture.hosting.layoutSubtreeIfNeeded()
        let crossWindowCount = try bindingCount(fixture)
        #expect(crossWindowCount > count)
        #expect(fixture.anchor.window === destination)
        #expect(fixture.surface.hostedView.window === destination)
        #expect(TerminalWindowPortalRegistry.isHostedView(fixture.surface.hostedView, boundTo: fixture.anchor))
        expectMatchingGeometry(fixture)

        fixture.anchor.viewDidMoveToWindow()
        let repeatedCount = try bindingCount(fixture)
        #expect(repeatedCount == crossWindowCount)
    }

    @Test
    func offWindowPriorityChangeRebindsWhenTheHostReturns() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let count = try bindingCount(fixture)
        fixture.hosting.removeFromSuperview()
        var updated = fixture.hosting.rootView
        updated.portalZPriority = 20
        fixture.hosting.rootView = updated
        fixture.hosting.layoutSubtreeIfNeeded()
        try #require(fixture.anchor.window == nil)

        fixture.secondSlot.addSubview(fixture.hosting)
        fixture.hosting.frame = fixture.secondSlot.bounds
        fixture.hosting.layoutSubtreeIfNeeded()
        let reboundCount = try bindingCount(fixture)
        #expect(reboundCount == count + 1)
        #expect(TerminalWindowPortalRegistry.isHostedView(fixture.surface.hostedView, boundTo: fixture.anchor))
        #expect(!fixture.surface.hostedView.isHidden)
        expectMatchingGeometry(fixture)
    }

    @Test
    func closedLeaseCannotBeReboundByAnOldWindowMoveCallback() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let count = try bindingCount(fixture)
        fixture.surface.teardownSurface()
        TerminalWindowPortalRegistry.detach(hostedView: fixture.surface.hostedView)
        fixture.anchor.viewDidMoveToWindow()
        let closedCount = try bindingCount(fixture)
        #expect(closedCount == count)
        #expect(!TerminalWindowPortalRegistry.isHostedView(fixture.surface.hostedView, boundTo: fixture.anchor))
    }

    enum Recovery: CaseIterable {
        case missingRegistryEntry
        case differentAnchor
        case detachedHostedView
        case wrongSameWindowParent
        case differentTerminalHostInSameWindow
        case staleEntryVisibility
    }

    private typealias Fixture = (
        window: NSWindow,
        root: NSView,
        secondSlot: NSView,
        hosting: NSHostingView<GhosttyTerminalView>,
        anchor: NSView,
        surface: TerminalSurface,
        focusSentinel: NSView
    )

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeFixture() throws -> Fixture {
        _ = NSApplication.shared
        let window = makeWindow()
        var fixtureCreated = false
        defer { if !fixtureCreated { closeWindow(window) } }
        let root = try #require(window.contentView)
        let firstSlot = NSView(frame: NSRect(x: 20, y: 40, width: 270, height: 300))
        let secondSlot = NSView(frame: NSRect(x: 380, y: 70, width: 310, height: 260))
        root.addSubview(firstSlot)
        root.addSubview(secondSlot)
        let focusSentinel = FocusSentinel(frame: NSRect(x: 2, y: 2, width: 8, height: 8))
        root.addSubview(focusSentinel)
        var config = CmuxSurfaceConfigTemplate()
        config.waitAfterCommand = true
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: config,
            initialCommand: "/usr/bin/true"
        )
        defer { if !fixtureCreated { surface.teardownSurface() } }
        let hosting = NSHostingView(rootView: GhosttyTerminalView(
            terminalSurface: surface,
            paneId: PaneID(),
            isActive: false,
            isVisibleInUI: true
        ))
        hosting.frame = firstSlot.bounds
        firstSlot.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        let anchor = try #require(TerminalWindowPortalRegistry.debugAnchorView(for: surface.hostedView))
        try #require(anchor.isDescendant(of: hosting))
        try #require(surface.hostedView.window === window)
        try #require(!surface.hostedView.isHidden)
        GhosttyTerminalView.debugEnableWindowMoveBindingCounts(in: anchor)
        fixtureCreated = true
        return (window, root, secondSlot, hosting, anchor, surface, focusSentinel)
    }

    private func bindingCount(_ fixture: Fixture) throws -> Int {
        try #require(GhosttyTerminalView.debugWindowMoveBindingCount(in: fixture.anchor))
    }

    private func expectMatchingGeometry(_ fixture: Fixture) {
        let expected = fixture.anchor.convert(fixture.anchor.bounds, to: nil)
        let hosted = fixture.surface.hostedView
        let actual = hosted.convert(hosted.bounds, to: nil)
        #expect(abs(actual.minX - expected.minX) <= 1)
        #expect(abs(actual.minY - expected.minY) <= 1)
        #expect(abs(actual.width - expected.width) <= 1)
        #expect(abs(actual.height - expected.height) <= 1)
    }

    private func close(_ fixture: Fixture) {
        fixture.surface.teardownSurface()
        fixture.hosting.removeFromSuperview()
        closeWindow(fixture.window)
    }

    private func closeWindow(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        window.orderOut(nil)
        window.close()
    }

    private final class FocusSentinel: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
}
