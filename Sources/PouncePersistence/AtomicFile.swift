import Darwin
import Foundation

/// Writes a file so readers see either the old contents or the new ones, never a partial file: the
/// bytes go to a temporary file in the same folder (mode 0600 from the start), which then replaces the
/// target with `rename(2)` (spec: `PouncePersistence`, atomic-write helper). An interrupted write
/// leaves the previous file untouched.
public enum AtomicFile {
    public enum WriteError: Error, Equatable {
        case create(errno: Int32)
        case write(errno: Int32)
        case rename(errno: Int32)
    }

    public static func write(_ data: Data, to url: URL, permissions: mode_t = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard descriptor >= 0 else { throw WriteError.create(errno: errno) }
        var failure: WriteError?
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count, let base = raw.baseAddress {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = .write(errno: errno)
                    return
                }
                offset += written
            }
        }
        if failure == nil, fsync(descriptor) != 0 {
            failure = .write(errno: errno)
        }
        close(descriptor)
        if let failure {
            unlink(temporary.path)
            throw failure
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw WriteError.rename(errno: code)
        }
    }
}
