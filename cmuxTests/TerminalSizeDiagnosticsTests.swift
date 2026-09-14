import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@Suite(.serialized)
@MainActor
struct TerminalSizeDiagnosticsTests {
    @Test(arguments: [1, 16])
    func disabledSizeDiagnosticsDoNotEvaluateMessages(callCount: Int) throws {
        // This test never enables diagnostics or writes a diagnostic file.
        try #require(ProcessInfo.processInfo.environment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] == nil)
        var evaluatedMessages = 0
        func message() -> String {
            evaluatedMessages += 1
            return "Terminal size diagnostic test \(evaluatedMessages)"
        }

        for _ in 0..<callCount {
            TerminalSurface.debugLogTerminalSizeForTesting(message())
        }

        #expect(evaluatedMessages == 0)
    }
}
#endif
