#if DEBUG
import Foundation
import Testing

@testable import LintelApp

/// Round-16 audit L-5: the QA bundle shares the Keychain services and the data folder with the real Lintel unless
/// `--qa` isolates them, so without `--qa` it refuses to start.
@Suite struct QAIdentityGuardTests {
    @Test func theQABundleWithoutQAArgumentsIsRefused() {
        let refused = QAIdentityGuard.decision(
            bundleID: "com.lintelapp.Lintel.QA", executableName: "Lintel-QA", arguments: ["/x/Lintel-QA"])
        guard case .refuse(let reason) = refused else {
            Issue.record("the QA bundle started without --qa")
            return
        }
        #expect(reason.contains("--qa") && reason.contains("docs/qa.md"))
        // Either identity alone is enough.
        #expect(
            QAIdentityGuard.decision(bundleID: "com.lintelapp.Lintel.QA", executableName: nil, arguments: [])
                != .allow)
        #expect(
            QAIdentityGuard.decision(
                bundleID: nil, executableName: "Lintel-QA", arguments: ["a", "-NSDocumentRevisions"])
                != .allow)
    }

    @Test func theQABundleWithAQAArgumentAndEveryOtherAppStartNormally() {
        #expect(
            QAIdentityGuard.decision(
                bundleID: "com.lintelapp.Lintel.QA", executableName: "Lintel-QA", arguments: ["x", "--qa"]) == .allow)
        #expect(
            QAIdentityGuard.decision(
                bundleID: "com.lintelapp.Lintel.QA", executableName: "Lintel-QA",
                arguments: ["x", "--qa-panel", "search"])
                == .allow)
        // The real app, and `swift run` (no bundle id, executable Lintel), are never touched by the guard.
        #expect(
            QAIdentityGuard.decision(bundleID: "com.lintelapp.Lintel", executableName: "Lintel", arguments: ["x"])
                == .allow)
        #expect(QAIdentityGuard.decision(bundleID: nil, executableName: "Lintel", arguments: []) == .allow)
    }

    /// The guard runs first thing in `main()`, before the application, the environment or any data exists.
    @Test func theGuardRunsBeforeAnythingElseInMain() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "Sources/LintelApp/LintelMain.swift"), encoding: .utf8)
        let guardCall = try #require(source.range(of: "QAIdentityGuard.decisionForThisProcess()"))
        let application = try #require(source.range(of: "NSApplication.shared"))
        #expect(guardCall.lowerBound < application.lowerBound)
    }
}
#endif
