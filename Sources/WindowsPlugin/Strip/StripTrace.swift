#if DEBUG
import Foundation

/// DEBUG only (QA): appends what the status item's click actually delivers to a file
/// (`plugins.windows.qaStripTrace=<path>`), so a scripted click shows where the system says it happened.
enum StripTrace {
    nonisolated(unsafe) private static var path: String?

    static func configure(path: String?) { self.path = path?.isEmpty == true ? nil : path }

    static func record(_ line: String) {
        guard let path, let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
#endif
