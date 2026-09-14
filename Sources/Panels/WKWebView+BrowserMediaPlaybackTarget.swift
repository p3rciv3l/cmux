import WebKit

extension WKWebView: BrowserMediaPlaybackTarget {
    func cmuxRequestMediaPlaybackState(_ completion: @escaping (WKMediaPlaybackState) -> Void) {
        requestMediaPlaybackState(completionHandler: completion)
    }

    func cmuxSetAllMediaPlaybackSuspended(_ suspended: Bool) {
        setAllMediaPlaybackSuspended(suspended, completionHandler: nil)
    }
}
