import Foundation

/// The sentence "Copy message" puts on the pasteboard so the recorder can tell the participants (MEET-1.6).
/// It says plainly that a recording is made and offers a way to object; it is not legal advice and it never
/// claims that anyone was informed. The language follows the system (`Localizable.xcstrings`, `en` and `pl`).
enum MeetingConsentText {
    static var sentence: String {
        String(
            localized: "I'm recording this meeting with Lintel to take notes. Tell me if you object.",
            comment: "Sentence the recorder pastes into the meeting chat to tell the participants about the recording")
    }
}
