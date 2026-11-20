import Foundation
import Testing

/// ADR 0011 / spec 1.1, 1.6: the graph, the one place a process starts, the one caller of `runContent`, and a logger
/// that only gets codes. These read the sources, like `NotesUIScanTests`.
@Suite struct SourceScanTests {
    private static let repositoryTargets = [
        "LintelKit", "LintelCore", "LintelPersistence", "LintelUI", "LintelApp", "AppsPlugin", "FilesPlugin",
        "ClipboardPlugin", "DictationPlugin", "MeetingsPlugin", "NotesPlugin", "WindowsPlugin",
    ]

    private static var root: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func sources() throws -> [(name: String, text: String)] {
        let dir = root.appending(path: "Sources/LintelProviders", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    private func targetText(_ name: String) throws -> String {
        let manifest = try String(contentsOf: Self.root.appending(path: "Package.swift"), encoding: .utf8)
        let start = try #require(manifest.range(of: "name: \"\(name)\""))
        let rest = manifest[start.upperBound...]
        let end =
            rest.range(of: "\n        ),")?.lowerBound ?? rest.range(of: "\n        ]")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test func theTargetDependsOnlyOnSpeech() throws {
        let target = try targetText("LintelProviders")
        #expect(target.contains("\"LintelSpeech\""))
        for name in Self.repositoryTargets { #expect(!target.contains("\"\(name)\""), "must not depend on \(name)") }
    }

    @Test func noSourceImportsAPluginOrTheApp() throws {
        let files = try Self.sources()
        #expect(!files.isEmpty)
        for file in files {
            for name in Self.repositoryTargets {
                #expect(!file.text.contains("import \(name)"), "\(file.name) imports \(name)")
            }
        }
    }

    @Test func onlyMeetingsPluginAndItsTestsDependOnIt() throws {
        let manifest = try String(contentsOf: Self.root.appending(path: "Package.swift"), encoding: .utf8)
        // Its own declaration, its test target, `MeetingsPlugin` (the notes provider, A5b), and the two test targets
        // that build a plugin with a fake runner (`MeetingsPluginTests`, `LintelAppTests`).
        let mentions = manifest.components(separatedBy: "\"LintelProviders\"").count - 1
        #expect(mentions == 5)
        let plugin = try targetText("MeetingsPlugin")
        #expect(plugin.contains("\"LintelProviders\""))
        for name in [
            "LintelApp", "AppsPlugin", "FilesPlugin", "ClipboardPlugin", "DictationPlugin", "NotesPlugin",
            "WindowsPlugin",
        ] {
            #expect(!(try targetText(name)).contains("\"LintelProviders\""), "\(name) must not depend on it")
        }
    }

    @Test func aProcessIsStartedOnlyInProviderProcess() throws {
        for file in try Self.sources() where file.name != "ProviderProcess.swift" {
            for pattern in [
                #"\bposix_spawn"#, #"\bProcess\("#, #"\bNSTask"#, #"\bsystem\("#, #"\bpopen\("#, #"\bexecv"#,
                #"\bfork\("#,
            ] {
                let found = file.text.range(of: pattern, options: .regularExpression) != nil
                #expect(!found, Comment(rawValue: "\(file.name) uses \(pattern)"))
            }
            #expect(!file.text.contains("URLSession"), "no network in phase 1")
        }
    }

    @Test func runContentIsCalledOnlyFromTheRunnersRun() throws {
        for file in try Self.sources() {
            let calls = file.text.components(separatedBy: "runContent(").count - 1
            switch file.name {
            case "ProviderRunner.swift": #expect(calls == 1)
            case "ProviderProcess.swift", "ProviderSystem.swift": break  // the declarations and implementations
            default: #expect(calls == 0, "\(file.name) calls runContent")
            }
        }
        let runner = try #require(try Self.sources().first { $0.name == "ProviderRunner.swift" }).text
        let run = try #require(runner.range(of: "public func run("))
        let probes = try #require(runner.range(of: "// MARK: probes"))
        let body = String(runner[run.lowerBound..<probes.lowerBound])
        let authorization = try #require(body.range(of: "await authorization()"))
        let content = try #require(body.range(of: "runContent("))
        #expect(authorization.lowerBound < content.lowerBound, "authorization must be asked before the start")
    }

    @Test func theLoggerGetsOnlyCodesCountsAndIds() throws {
        let allowedInterpolations: Set<String> = [
            "code.rawValue, privacy: .public", "provider.rawValue, privacy: .public", "millis, privacy: .public",
        ]
        var loggerLines = 0
        for file in try Self.sources() {
            for line in file.text.split(separator: "\n") where line.contains("logger.") || line.contains("Logger(") {
                loggerLines += 1
                var rest = line[...]
                while let open = rest.range(of: "\\(") {
                    let after = rest[open.upperBound...]
                    let close = try #require(after.firstIndex(of: ")"))
                    let expression = String(after[..<close])
                    #expect(allowedInterpolations.contains(expression), "\(file.name) logs \(expression)")
                    rest = after[after.index(after: close)...]
                }
            }
            #expect(!file.text.contains("print("), "\(file.name) prints")
            #expect(!file.text.contains("NSLog"), "\(file.name) uses NSLog")
        }
        #expect(loggerLines >= 1)
    }

    @Test func noTrapsOutsideTests() throws {
        for file in try Self.sources() {
            #expect(!file.text.contains("fatalError"), Comment(rawValue: file.name))
            #expect(!file.text.contains("try!"), Comment(rawValue: file.name))
            #expect(!file.text.contains("preconditionFailure"), Comment(rawValue: file.name))
        }
    }
}
