import WebKit

/// Routes document fullscreen reports to the WebView that owns their presentation.
/// WebKit owns this stateless adapter; it never retains a browser panel or WebView.
@MainActor
final class BrowserContainedFullscreenController: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "cmuxContainedFullscreen"

    static func install(on userContentController: WKUserContentController) {
        let source = BrowserContainedFullscreenScript.source
        guard !userContentController.userScripts.contains(where: { $0.source == source }) else { return }
        userContentController.add(BrowserContainedFullscreenController(), name: messageHandlerName)
        userContentController.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageHandlerName,
              message.frameInfo.isMainFrame,
              let webView = message.webView as? CmuxWebView,
              let body = message.body as? [String: Any],
              let documentID = body["documentID"] as? String,
              webView.cmuxContainedFullscreenDocumentID == documentID,
              let active = body["active"] as? Bool else { return }
        // Apply synchronously in WebKit delivery order so navigation reset cannot
        // be overtaken by a queued task from the document being replaced.
        webView.cmuxSetContainedFullscreenActive(active)
    }
}
