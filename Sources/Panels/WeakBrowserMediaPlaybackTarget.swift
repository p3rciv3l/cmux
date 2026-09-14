/// A non-owning reference used by suspension leases so browser panes can close normally.
@MainActor
final class WeakBrowserMediaPlaybackTarget {
    weak var value: (any BrowserMediaPlaybackTarget)?

    init(_ value: any BrowserMediaPlaybackTarget) {
        self.value = value
    }
}
