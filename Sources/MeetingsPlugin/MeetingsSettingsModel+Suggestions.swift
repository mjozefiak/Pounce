import Foundation

/// An app in one of the suggestion lists.
struct SuggestionApp: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
}

enum ExtraAppError: Equatable, Sendable {
    case invalid
    case duplicate
    case tooMany
}

extension MeetingsSettingsModel {
    /// More than this many added apps is not a list a person edits by hand.
    static let maximumExtraApps = 50

    func detectorStatusChanged(_ status: MeetingDetector.Status) {
        suggestionStatus = status
    }

    func reloadSuggestionLists() {
        mutedApps = settings.suggestMutedBundleIDs.map { SuggestionApp(id: $0, name: appName($0)) }
        extraApps = settings.suggestExtraBundleIDs.map { SuggestionApp(id: $0, name: appName($0)) }
    }

    /// "Nie pytaj dla tej aplikacji" taken back: the app may be suggested again.
    func unmute(_ bundleID: String) {
        settings.setSuggestMutedBundleIDs(settings.suggestMutedBundleIDs.filter { $0 != bundleID })
        reloadSuggestionLists()
        suggestionsChanged()
    }

    /// Adds an app (a browser, for instance) whose microphone use counts as a meeting. Returns whether it was
    /// added; the reason it was not is in `extraAppError`.
    @discardableResult
    func addExtraApp(_ text: String) -> Bool {
        extraAppError = nil
        let bundleID = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidBundleID(bundleID) else {
            extraAppError = .invalid
            return false
        }
        var extra = settings.suggestExtraBundleIDs
        guard !extra.contains(bundleID) else {
            extraAppError = .duplicate
            return false
        }
        guard extra.count < Self.maximumExtraApps else {
            extraAppError = .tooMany
            return false
        }
        extra.append(bundleID)
        settings.setSuggestExtraBundleIDs(extra)
        reloadSuggestionLists()
        suggestionsChanged()
        return true
    }

    func removeExtraApp(_ bundleID: String) {
        extraAppError = nil
        settings.setSuggestExtraBundleIDs(settings.suggestExtraBundleIDs.filter { $0 != bundleID })
        reloadSuggestionLists()
        suggestionsChanged()
    }

    /// A reverse-DNS identifier: letters, digits, `.`, `-` and `_`, at least one dot, at most 255 characters.
    static func isValidBundleID(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 255, text.contains("."), !text.hasPrefix("."), !text.hasSuffix(".")
        else { return false }
        return text.unicodeScalars.allSatisfy {
            ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0))))
                || $0 == "." || $0 == "-" || $0 == "_"
        }
    }
}
