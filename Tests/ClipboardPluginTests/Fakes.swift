import Foundation
import PounceKit
import Security
import SwiftUI
import Synchronization
import os

@testable import ClipboardPlugin

/// A Keychain in memory whose reads, adds and deletes can be made to fail with a chosen error.
final class FakeKeychain: KeychainClient {
    struct State {
        var items: [String: Data] = [:]
        var readError: KeychainError?
        var addError: KeychainError?
        var reads = 0
        var adds = 0
        var deletes = 0
    }

    let state = Mutex(State())

    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data {
        let result: Result<Data, KeychainError> = state.withLock { state in
            state.reads += 1
            if let error = state.readError { return .failure(error) }
            guard let data = state.items["\(service)/\(account)"] else { return .failure(.itemNotFound) }
            return .success(data)
        }
        return try result.get()
    }

    func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError) {
        let error: KeychainError? = state.withLock { state in
            state.adds += 1
            if let error = state.addError { return error }
            guard state.items["\(service)/\(account)"] == nil else { return .unexpected(status: errSecDuplicateItem) }
            state.items["\(service)/\(account)"] = data
            return nil
        }
        if let error { throw error }
    }

    func deleteGenericPassword(service: String, account: String) throws(KeychainError) {
        let removed = state.withLock { state in
            state.deletes += 1
            return state.items.removeValue(forKey: "\(service)/\(account)")
        }
        if removed == nil { throw .itemNotFound }
    }

    var storedKeyCount: Int { state.withLock { $0.items.count } }
}

/// A temporary directory removed when the test object is released.
final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "pounce-clipboard-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Keys from a fixed fake master key, so tests never touch a real Keychain.
func testKeys(_ byte: UInt8 = 7) throws -> ClipKeys {
    guard let keys = ClipKeys(master: Data(repeating: byte, count: 32)) else { throw TestFailure.keys }
    return keys
}

enum TestFailure: Error {
    case keys
}

func textItem(_ text: String) -> PasteboardItem {
    PasteboardItem(representations: [
        PasteboardRepresentation(type: PasteboardRepresentation.plainTextType, data: Data(text.utf8))
    ])
}

func draft(
    _ text: String,
    kind: ClipKind = .text,
    at date: Date = Date(timeIntervalSince1970: 1_000_000),
    items: [PasteboardItem]? = nil,
    source: String? = "com.example.editor"
) -> ClipDraft {
    ClipDraft(
        kind: kind,
        previewText: text,
        items: items ?? [textItem(text)],
        sourceBundleID: source,
        sourceAppName: source == nil ? nil : "Editor",
        capturedAt: date
    )
}
