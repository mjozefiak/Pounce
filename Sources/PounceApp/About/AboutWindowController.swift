import AppKit
import SwiftUI

/// What the About window shows, read from the app bundle.
struct AboutInfo: Equatable {
    static let websiteURL = URL(string: "https://mjozefiak.github.io/Pounce/")
    static let sourceURL = URL(string: "https://github.com/mjozefiak/Pounce")
    static let noticesResource = "THIRD_PARTY_NOTICES"

    /// `CFBundleShortVersionString` and `CFBundleVersion`; `nil` for an unbundled build (`swift run`).
    let version: String?
    let build: String?
    let copyright: String?
    /// The contents of `THIRD_PARTY_NOTICES.txt`; `nil` when the bundle has no copy (`swift run`).
    let notices: String?

    init(version: String?, build: String?, copyright: String?, notices: String?) {
        self.version = version
        self.build = build
        self.copyright = copyright
        self.notices = notices
    }

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        let notices = bundle.url(forResource: Self.noticesResource, withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        self.init(
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            copyright: info["NSHumanReadableCopyright"] as? String,
            notices: notices
        )
    }

    var versionText: String {
        guard let version else {
            return String(localized: "Development build", comment: "About window: version of an unbundled build")
        }
        guard let build else {
            return String(localized: "Version \(version)", comment: "About window: version without a build number")
        }
        return String(localized: "Version \(version) (\(build))", comment: "About window: version and build number")
    }
}

/// The About window (menu bar → About Pounce): version, licence, links and the third-party notices that
/// the licences of the bundled libraries require (`Resources/THIRD_PARTY_NOTICES.txt`). Replaces the
/// standard About panel, which cannot show a long notices file.
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let info: AboutInfo

    /// False in QA mode: the window is ordered front without activating Pounce.
    var activatesApp = true

    init(info: AboutInfo = AboutInfo(bundle: .main)) {
        self.info = info
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: AboutView(info: info))
            controller.sizingOptions = [.preferredContentSize]
            let window = ShellWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.title = String(localized: "About Pounce", comment: "Menu bar menu item that opens the About window")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        if activatesApp {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct AboutView: View {
    let info: AboutInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Pounce")
                        .font(.title.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(info.versionText)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(
                        "A fast launcher for apps, files and your clipboard history.",
                        comment: "About window: one-line description"
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if let copyright = info.copyright {
                    Text(verbatim: copyright)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    if let url = AboutInfo.websiteURL {
                        Link(destination: url) {
                            Text("Website", comment: "About window: link to the landing page")
                        }
                    }
                    if let url = AboutInfo.sourceURL {
                        Link(destination: url) {
                            Text("Source Code", comment: "About window: link to the GitHub repository")
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Third-Party Notices", comment: "About window: section title")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ScrollView {
                    Text(verbatim: info.notices ?? AboutView.missingNotices)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 220)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator)
                }
                .accessibilityLabel(Text("Third-Party Notices", comment: "About window: section title"))
            }
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    static var missingNotices: String {
        String(
            localized: "The notices are in THIRD_PARTY_NOTICES.txt in the app bundle and in the source repository.",
            comment: "About window: shown when the notices file is missing from the bundle"
        )
    }
}
