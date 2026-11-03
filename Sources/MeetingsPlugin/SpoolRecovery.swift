import Foundation

/// What a meeting's spool looks like to crash recovery.
enum SpoolCondition: Equatable, Sendable {
    /// At least one track opens and its first frame authenticates (a truncated tail is still readable).
    case readable
    /// There is no spool file to read (never created, or already deleted).
    case absent
    /// The files exist but cannot be read for good: a wrong key (the Keychain item was recreated), a damaged
    /// header or frame, an unsupported version.
    case unreadable
    /// The disk gave an error (I/O, descriptors): it may work later, so nothing is concluded from it.
    case indeterminate
}

extension SpoolStorage {
    /// Opens each track and decrypts its first frame; nothing else is read, so this is cheap even for a long
    /// meeting. Never modifies or deletes anything.
    func condition(of meeting: UUID, keys: MeetingKeys) -> SpoolCondition {
        var sawFile = false
        var sawUnreadable = false
        var sawIndeterminate = false
        for track in SpoolTrack.allCases {
            let file = file(for: meeting, track: track)
            switch Self.presence(of: file) {
            case .missing: continue
            case .unknown:
                sawFile = true
                sawIndeterminate = true
                continue
            case .present: sawFile = true
            }
            do {
                let reader = try SpoolReader(file: file, meeting: meeting, track: track, keys: keys)
                _ = try reader.nextSamples()
                return .readable
            } catch let error as SpoolError {
                if case .ioFailure(let code) = error, code != ELOOP {
                    sawIndeterminate = true
                } else {
                    sawUnreadable = true
                }
            } catch {
                sawIndeterminate = true
            }
        }
        guard sawFile else { return .absent }
        if sawIndeterminate { return .indeterminate }
        return sawUnreadable ? .unreadable : .absent
    }

    /// Removes a meeting's spool and says whether nothing of it is left. Only a removal that the result
    /// confirms (or a spool that is gone anyway) may be recorded as `audio_state = deleted`.
    func removeConfirmed(meeting: UUID, keys: MeetingKeys) -> Bool {
        let name = Self.name(of: meeting)
        if removeSpools(forMeetings: [name]).contains(name) { return true }
        return condition(of: meeting, keys: keys) == .absent
    }

    func hasTrackFile(of meeting: UUID, _ track: SpoolTrack) -> Bool {
        Self.presence(of: file(for: meeting, track: track)) != .missing
    }

    private enum Presence { case present, missing, unknown }

    /// `lstat`, so that a link counts as present and a folder the process cannot enter is "unknown", never
    /// "missing": a missing spool is a conclusion (`audio_state` = `deleted`), a permission error is not.
    private static func presence(of url: URL) -> Presence {
        var info = stat()
        if lstat(url.path, &info) == 0 { return .present }
        return errno == ENOENT || errno == ENOTDIR ? .missing : .unknown
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// Starts a meeting's `orphanAudioDays` clock now: the spool of a meeting recovery has just turned
    /// `incomplete` gets a full grace period from the moment the user could first see it, however long the
    /// app was closed after the crash.
    func touch(meeting: UUID, at date: Date) {
        let directory = directory(for: meeting)
        guard !isSymbolicLink(directory) else { return }
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: directory.path)
    }

    /// Removes every spool folder. Used only when the Keychain key was definitely missing and had to be
    /// recreated: no spool can be read with the new key. Symbolic links are removed as links, not followed.
    @discardableResult
    func removeAll() -> Int {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return 0
        }
        return items.filter { (try? fileManager.removeItem(at: $0)) != nil }.count
    }
}
