import Foundation
import SwiftUI
import Testing

@testable import NotesPlugin

/// The motion policy as a pure function: nothing here waits for an animation or opens a window.
@Suite("Notes motion")
struct NotesMotionTests {
    @Test("every kind is a short ease of 0.15 to 0.25 s")
    func durationsAreShort() {
        for kind in NotesMotion.Kind.allCases {
            let seconds = NotesMotion.duration(kind)
            #expect((0.15...0.25).contains(seconds), "\(kind)")
            #expect(NotesMotion.animation(kind, reduceMotion: false) != nil, "\(kind)")
        }
    }

    @Test("Reduce Motion gives no animation and no motion for any kind")
    func reduceMotionIsInstant() {
        for kind in NotesMotion.Kind.allCases {
            #expect(NotesMotion.animation(kind, reduceMotion: true) == nil, "\(kind)")
            #expect(NotesMotion.animation(kind, reduceMotion: true, disabled: true) == nil, "\(kind)")
        }
        #expect(!NotesMotion.allowsMotion(reduceMotion: true))
    }

    @Test("QA runs switch animations off, so a snapshot is deterministic")
    func disabledIsInstant() {
        for kind in NotesMotion.Kind.allCases {
            #expect(NotesMotion.animation(kind, reduceMotion: false, disabled: true) == nil, "\(kind)")
        }
        #expect(!NotesMotion.allowsMotion(reduceMotion: false, disabled: true))
        #expect(NotesMotion.allowsMotion(reduceMotion: false))
    }

    @MainActor
    @Test("a normal run animates: the model's switch is off by default")
    func modelDefault() {
        let model = NotesWorkspaceModel(
            environment: NotesWorkspaceModel.Environment(
                library: NoteLibrary(box: SourceBox([])), pasteboard: RecordingPasteboard()))
        #expect(!model.animationsDisabled)
    }

    @Test("the views animate only through NotesMotion, so Reduce Motion can never be bypassed")
    func noAnimationOutsideTheHelper() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appending(path: "Sources/NotesPlugin")
        let enumerator = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var offences: [String] = []
        var files = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            files += 1
            guard file.lastPathComponent != "NotesMotion.swift" else { continue }
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if code.contains("withAnimation") || code.contains(".animation(") || code.contains(".transition(") {
                    offences.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(files > 20)
        #expect(offences.isEmpty, "use notesAnimation / notesFade: \(offences)")
    }
}
