import Foundation
import LintelCore

/// Where each block of `MarkdownBlocks.split` sits in the editor's text: the gutter draws a bar beside exactly
/// that range. Pure.
///
/// A block is a trimmed run of consecutive lines of the text, so it is an exact substring; blocks come in order
/// and are separated only by blank lines, which a block never contains outside a code fence. Searching forward
/// from the end of the previous block therefore finds the block itself and nothing earlier.
enum BlockLocator {
    /// The UTF-16 range of each block of `text`, in order. A block that cannot be found (text with `\r` line
    /// breaks, which `split` normalises) has no range, and the blocks after it are searched from the same place.
    static func ranges(of blocks: [String], in text: String) -> [NSRange?] {
        let source = text as NSString
        var cursor = 0
        return blocks.map { block in
            let found = source.range(
                of: block, options: [.literal], range: NSRange(location: cursor, length: source.length - cursor))
            guard found.location != NSNotFound else { return nil }
            cursor = found.location + found.length
            return found
        }
    }
}
