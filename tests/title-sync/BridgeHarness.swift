import Foundation

@main
struct BridgeHarness {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let bridge = try CodexTabTitleSync(
            sessionID: args[1], executable: URL(fileURLWithPath: args[2]),
            home: URL(fileURLWithPath: args[3]),
            sessionNameChanged: { print("INITIAL " + $0); fflush(stdout) },
            failure: { print("ERROR " + $0); fflush(stdout) },
            didRename: { print("RENAMED"); fflush(stdout) }
        )
        // A pipe-driven harness exercises the actual bridge without AppKit or user sessions.
        for try await line in FileHandle.standardInput.bytes.lines {
            if line == "QUIT" { break }
            let start = ContinuousClock.now
            bridge.rename(line)
            print("QUEUED \(start.duration(to: .now))"); fflush(stdout)
        }
        withExtendedLifetime(bridge) {}
    }
}
