import Foundation

/// Pure text hygiene for Markdown that comes from people or from a model (transcripts, speaker names, notes a
/// model wrote). No I/O. Moved here from the Meetings export so Notes can share it
/// (spec `2026-11-04-notes-workspace`, step 1.4).
public enum MarkdownText {
    /// Removes invisible and bidirectional control characters; control characters and line breaks become spaces
    /// (line breaks stay when `keepNewlines`, and runs of spaces made by this collapse into one). The zero-width
    /// (non-)joiners stay: scripts and emoji need them.
    public static func cleaned(_ text: String, keepNewlines: Bool) -> String {
        var result = String.UnicodeScalarView()
        var previousWasSpace = false
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            if isLineBreak(scalar) {
                if keepNewlines {
                    result.append("\n")
                    previousWasSpace = false
                } else if !previousWasSpace {
                    result.append(" ")
                    previousWasSpace = true
                }
                continue
            }
            if isControl(scalar) {
                if !previousWasSpace {
                    result.append(" ")
                    previousWasSpace = true
                }
                continue
            }
            if isInvisible(scalar) { continue }
            result.append(scalar)
            previousWasSpace = scalar == " "
        }
        return String(result)
    }

    /// Strips what could hide or reorder text from Markdown that keeps its structure: bidirectional controls,
    /// zero-width and other invisible characters and control characters are removed, line breaks become `\n`,
    /// and tabs stay (they carry indentation and code). Nothing else changes: spaces are not collapsed and
    /// fenced code blocks are stripped like the rest, because a hidden character is as harmful there.
    public static func strippingBidiAndControls(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            if isLineBreak(scalar) {
                result.append("\n")
            } else if scalar == "\t" {
                result.append(scalar)
            } else if isControl(scalar) || isInvisible(scalar) {
                continue
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}" || scalar == "\u{85}"
    }

    /// C0 and C1 controls (line breaks are handled before this).
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    /// Characters that draw nothing or reorder text. U+200C and U+200D (joiners) are not among them.
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180F: true
        case 0x200B, 0x200E, 0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F: true
        case 0x2800, 0x3164, 0xFEFF, 0xFFA0, 0xFFF9...0xFFFB: true
        case 0xFE00...0xFE0D, 0xE0000...0xE007F: true
        default: false
        }
    }
}
