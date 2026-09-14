import WebKit

/// A WebKit media surface whose aggregate playback can be queried and suspended.
@MainActor
protocol BrowserMediaPlaybackTarget: AnyObject {
    func cmuxRequestMediaPlaybackState(_ completion: @escaping (WKMediaPlaybackState) -> Void)
    func cmuxSetAllMediaPlaybackSuspended(_ suspended: Bool)
}
