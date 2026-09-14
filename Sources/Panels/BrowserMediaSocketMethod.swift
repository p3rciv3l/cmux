/// Browser media methods exposed through the local control socket.
enum BrowserMediaSocketMethod: String, CaseIterable {
    case suspendAll = "browser.media.suspend_all"
    case resumeAll = "browser.media.resume_all"
}
