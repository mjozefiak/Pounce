import AppKit
import LintelKit
import LintelUI
import SwiftUI

/// One page of the welcome screen.
struct WelcomePage: Identifiable {
    enum Kind {
        /// What Lintel is and which steps follow; shown on the very first launch only.
        case intro
        /// The Shortcut step (Q10, spec step 1.2b).
        case shortcut
        /// A plugin's `onboardingSteps` entry.
        case plugin(OnboardingStep)
        /// The final "You're set" page that points at the main window (spec step 6.1).
        case done
    }

    static let introID = "intro"
    static let shortcutID = "shortcut"
    static let doneID = "done"

    let kind: Kind

    var id: String {
        switch kind {
        case .intro: Self.introID
        case .shortcut: Self.shortcutID
        case .done: Self.doneID
        case .plugin(let step): step.id
        }
    }

    var title: String {
        switch kind {
        case .intro:
            String(localized: "Welcome", comment: "Welcome screen: title of the first page")
        case .shortcut:
            String(localized: "Shortcut", comment: "Welcome screen: title of the shortcut page")
        case .plugin(let step):
            String(localized: step.title)
        case .done:
            String(localized: "You’re set", comment: "Welcome screen: title of the final page")
        }
    }

    var symbolName: String {
        switch kind {
        case .intro: "circle.circle"
        case .shortcut: "keyboard"
        case .done: "checkmark.circle"
        case .plugin(let step): step.symbolName
        }
    }

    /// The large heading: the introduction greets, every other page shows its title.
    var heading: String {
        switch kind {
        case .intro: String(localized: "Welcome to Lintel", comment: "Onboarding window title")
        case .shortcut, .plugin, .done: title
        }
    }
}

/// The footer of one welcome page: which buttons are shown and what the primary one says. Pure, so the keyboard
/// paths are tested without a window: Return is always the primary button, Escape is Skip whenever Skip is shown.
struct WelcomeFooter: Equatable {
    enum Primary: Equatable {
        case continueToNext
        case useShortcut
        case done
        /// The final page: opens the main window, then completes the flow.
        case openNotes
    }

    var primary: Primary
    var showsBack: Bool
    var isBackEnabled: Bool
    var showsSkip: Bool

    /// Skip on every page, as the prototype draws it; Back only after the first page.
    init(page: WelcomePage, isFirst: Bool, isLast: Bool) {
        showsBack = !isFirst
        isBackEnabled = !isFirst
        showsSkip = true
        switch page.kind {
        case .intro: primary = .continueToNext
        case .shortcut: primary = .useShortcut
        case .done: primary = .openNotes
        case .plugin: primary = isLast ? .done : .continueToNext
        }
    }

    /// The footer of the flow's current page, or `nil` when the flow is finished.
    init?(flow: WelcomeFlow) {
        guard let page = flow.current else { return nil }
        self.init(page: page, isFirst: flow.isFirst, isLast: flow.isLast)
    }

    var primaryTitle: String {
        switch primary {
        case .continueToNext: String(localized: "Continue", comment: "Onboarding button that goes to the next step")
        case .useShortcut:
            String(localized: "Use This Shortcut", comment: "Onboarding button that confirms the shortcut")
        case .done: String(localized: "Done", comment: "Onboarding button on the last step")
        case .openNotes:
            String(localized: "Open Lintel", comment: "Settings label of the main shortcut")
        }
    }

    /// Return: moves on (and on the final page first opens the main window).
    func performPrimary(_ flow: WelcomeFlow, openMainWindow: () -> Void) {
        flow.advance()
        if primary == .openNotes {
            openMainWindow()
        }
    }

    /// Escape: skips the page on screen.
    func performSkip(_ flow: WelcomeFlow) {
        guard showsSkip else { return }
        flow.advance(skipping: true)
    }
}

/// The welcome screen's navigation (spec step 4.2): an ordered list of pages, Back, Skip and Continue.
/// It knows nothing about settings; the controller is told about each finished page.
@Observable
final class WelcomeFlow {
    let pages: [WelcomePage]
    private(set) var index: Int
    /// Pages left with Continue or Skip in this session, shown with a checkmark.
    private(set) var finishedPageIDs: Set<String> = []

    /// Called when a page is left forward: the page and whether it was skipped.
    @ObservationIgnored var onFinish: (WelcomePage, _ skipped: Bool) -> Void = { _, _ in }
    /// Called after the last page.
    @ObservationIgnored var onComplete: () -> Void = {}

    init(pages: [WelcomePage], startAt id: String? = nil) {
        self.pages = pages
        self.index = id.flatMap { id in pages.firstIndex { $0.id == id } } ?? 0
    }

    var current: WelcomePage? { pages.indices.contains(index) ? pages[index] : nil }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index >= pages.count - 1 }

    /// Continue (or Skip): records the page and moves on, or completes after the last page.
    func advance(skipping: Bool = false) {
        guard let page = current else { return }
        finishedPageIDs.insert(page.id)
        onFinish(page, skipping)
        if isLast {
            onComplete()
        } else {
            index += 1
            announceCurrentPage()
        }
    }

    func back() {
        guard !isFirst else { return }
        index -= 1
        announceCurrentPage()
    }

    /// "Step 2 of 4: Shortcut", for VoiceOver after the page changes.
    var positionDescription: String {
        guard let page = current else { return "" }
        return String(
            localized: "Step \(index + 1) of \(pages.count): \(page.title)",
            comment: "Welcome screen: VoiceOver announcement of the current step")
    }

    private func announceCurrentPage() {
        AccessibilityNotification.Announcement(positionDescription).post()
    }
}

/// The welcome screen (spec step 4.2, single column since step 6.5g): one window that combines the Shortcut step
/// with the enabled plugins' `onboardingSteps` and ends on the "You're set" page. Every step can be skipped.
///
/// On the first launch it starts with a short introduction. Each step is shown until it is finished or
/// skipped: the Shortcut step until `app.onboarding.shortcutCompleted`, a plugin step until its id is in
/// `app.onboarding.completedSteps`. A plugin step added by an update therefore appears alone on the next
/// launch. Closing the window skips the step on screen. Plugin steps not reached yet appear on the next
/// launch; the introduction and the Shortcut step count as answered once the window closes, so a closed
/// first launch never shows them again (`BACKWARD_COMPATIBILITY.md` §3).
final class OnboardingController: NSObject, NSWindowDelegate {
    private let hotkeys: HotkeyService
    private let settings: AppSettings
    private let pluginSteps: () -> [OnboardingStep]
    private var window: NSWindow?
    private(set) var flow: WelcomeFlow?

    /// False in QA mode: the window is ordered front without activating Lintel.
    var activatesApp = true

    /// Opens the main window from the final page (a property, so the trailing `pluginSteps` closure of the
    /// initializer stays unambiguous).
    var openMainWindow: () -> Void = {}

    init(
        hotkeys: HotkeyService, settings: AppSettings,
        pluginSteps: @escaping () -> [OnboardingStep] = { [] }
    ) {
        self.hotkeys = hotkeys
        self.settings = settings
        self.pluginSteps = pluginSteps
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Whether `--qa-onboarding-step` can open `id`: the introduction, the Shortcut step, an active plugin's step,
    /// and the final page.
    static func isKnownPage(_ id: String, pluginStepIDs: [String]) -> Bool {
        [WelcomePage.introID, WelcomePage.shortcutID, WelcomePage.doneID].contains(id) || pluginStepIDs.contains(id)
    }

    /// The plugin step on screen, if any.
    var currentPluginStep: String? {
        guard let page = flow?.current, case .plugin(let step) = page.kind else { return nil }
        return step.id
    }

    /// The active plugins' steps not completed yet, in plugin order.
    var pendingPluginSteps: [OnboardingStep] {
        let completed = Set(settings.completedOnboardingSteps)
        return pluginSteps().filter { !completed.contains($0.id) }
    }

    /// Whether launching should show the welcome screen at all.
    var hasPendingSteps: Bool {
        !settings.shortcutOnboardingCompleted || !pendingPluginSteps.isEmpty
    }

    /// The pages still to show: the introduction and the Shortcut step on the first launch, then every
    /// pending plugin step.
    var pendingPages: [WelcomePage] {
        var pages: [WelcomePage] = []
        if !settings.shortcutOnboardingCompleted {
            pages.append(WelcomePage(kind: .intro))
            pages.append(WelcomePage(kind: .shortcut))
        }
        pages += pendingPluginSteps.map { WelcomePage(kind: .plugin($0)) }
        return withFinalPage(pages)
    }

    /// Appends the "You're set" page to a non-empty list.
    private func withFinalPage(_ pages: [WelcomePage]) -> [WelcomePage] {
        guard !pages.isEmpty else { return pages }
        return pages + [WelcomePage(kind: .done)]
    }

    /// Shows the welcome screen with the pending pages, if any.
    func showPendingSteps() {
        let pages = pendingPages
        guard !pages.isEmpty else { return }
        show(pages)
    }

    /// Shows every page (the introduction, the Shortcut step and every active plugin step), starting at
    /// `id` when given. QA uses it to capture any page regardless of what was completed.
    func showAllSteps(startingAt id: String? = nil) {
        let pages = withFinalPage(
            [WelcomePage(kind: .intro), WelcomePage(kind: .shortcut)]
                + pluginSteps().map { WelcomePage(kind: .plugin($0)) })
        show(pages, startingAt: id)
    }

    func close() {
        window?.close()
    }

    /// Closing the window counts as skipping the step on screen.
    func windowWillClose(_ notification: Notification) {
        if !settings.shortcutOnboardingCompleted {
            settings.shortcutOnboardingCompleted = true
        }
        if let currentPluginStep {
            markCompleted(currentPluginStep)
        }
        flow = nil
        window = nil
    }

    private func show(_ pages: [WelcomePage], startingAt id: String? = nil) {
        hotkeys.refreshDefault()
        let flow = WelcomeFlow(pages: pages, startAt: id)
        flow.onFinish = { [weak self] page, skipped in self?.finish(page, skipped: skipped) }
        flow.onComplete = { [weak self] in self?.complete() }
        self.flow = flow
        let openMainWindow = { [weak self] in self?.openMainWindow() ?? () }
        present(AnyView(WelcomeColumnView(flow: flow, hotkeys: hotkeys, openMainWindow: openMainWindow)))
    }

    private func finish(_ page: WelcomePage, skipped: Bool) {
        switch page.kind {
        case .intro, .done:
            break
        case .shortcut:
            if skipped {
                hotkeys.resetToDefault()
            }
            settings.shortcutOnboardingCompleted = true
        case .plugin(let step):
            markCompleted(step.id)
        }
    }

    private func complete() {
        flow = nil
        window?.close()
        window = nil
    }

    private func markCompleted(_ id: String) {
        var completed = settings.completedOnboardingSteps
        guard !completed.contains(id) else { return }
        completed.append(id)
        settings.completedOnboardingSteps = completed
    }

    private func present(_ view: AnyView) {
        let controller = NSHostingController(rootView: view.lintelBrand())
        controller.sizingOptions = [.preferredContentSize]
        if let window {
            window.contentViewController = controller
            return
        }
        let window = ShellWindow(contentViewController: controller)
        // The prototype draws only the traffic lights: the title stays for VoiceOver and the Window menu.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The prototype's `--win` (also under the transparent title bar).
        window.backgroundColor = LintelBrand.windowBackgroundColor
        window.title = String(localized: "Welcome to Lintel", comment: "Onboarding window title")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        if activatesApp {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }
}

/// The Shortcut page: a recorder prefilled with the default shortcut (⌘Space, or ⌃⌥Space while
/// Spotlight holds ⌘Space) and, when Spotlight holds it, how to free it. "Use This Shortcut" keeps what
/// the recorder shows; "Skip" keeps the automatic default (Q10).
struct ShortcutStepContent: View {
    let hotkeys: HotkeyService
    /// The welcome window shows the explanation under its heading instead.
    var showsExplanation = true

    static var explanation: String {
        String(
            localized: "Press this shortcut anywhere to open Lintel. Keep the suggested one or record your own.",
            comment: "Onboarding step explanation")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsExplanation {
                Text(Self.explanation)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent {
                MainShortcutRecorder(hotkeys: hotkeys)
            } label: {
                Text("Open Lintel", comment: "Settings label of the main shortcut")
            }
            if hotkeys.spotlightHoldsCommandSpace {
                GroupBox {
                    SpotlightShortcutBanner()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("You can change it later in Settings → General.", comment: "Onboarding hint")
                .font(.callout)
                .foregroundStyle(LintelBrand.secondaryText)
        }
    }
}

/// The single-column welcome window of the prototype `shell-welcome-*` (spec step 6.5g): the Lintel mark, the heading, one line of text and the page's own controls, centred in a
/// 600 pt window; below a hairline, Skip (Escape) on the left and the one primary button (Return) on the right.
struct WelcomeColumnView: View {
    static let width: CGFloat = 600
    /// The prototype's 420 pt window less the title bar, which SwiftUI keeps as the top safe area.
    static let minHeight: CGFloat = 388

    let flow: WelcomeFlow
    let hotkeys: HotkeyService
    var openMainWindow: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if let page = flow.current {
                VStack(alignment: .leading, spacing: 0) {
                    LintelMark(ring: LintelBrand.ink)
                        .frame(width: 44, height: 44)
                        .padding(.bottom, 10)
                    Text(page.heading)
                        .font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 4)
                    if let text = Self.text(for: page, shortcut: hotkeys.mainShortcut?.displayString) {
                        Text(text)
                            .foregroundStyle(LintelBrand.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    pageContent(page)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 40)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(flow.positionDescription)
            }
            // The prototype's footer border (`--hair`).
            LintelDivider()
            WelcomeColumnFooter(flow: flow, openMainWindow: openMainWindow)
        }
        .frame(width: Self.width)
        .frame(minHeight: Self.minHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The line under the heading; plugin pages bring their own text.
    static func text(for page: WelcomePage, shortcut: String?) -> String? {
        switch page.kind {
        case .intro:
            String(
                localized:
                    "Search apps and files, paste from history, dictate, keep meeting notes. All on this Mac.",
                comment: "Welcome screen: text of the first page")
        case .shortcut:
            ShortcutStepContent.explanation
        case .plugin:
            nil
        case .done:
            if let shortcut {
                String(
                    localized:
                        "Open Lintel with \(shortcut). Settings and meetings are in the Lintel window: click the Dock icon or press ⌘,.",
                    comment: "Welcome screen: final page text; the argument is the main shortcut, such as ⌘Space")
            } else {
                String(
                    localized: "Settings and meetings are in the Lintel window: click the Dock icon or press ⌘,.",
                    comment: "Welcome screen: final page text while no main shortcut is set")
            }
        }
    }

    @ViewBuilder private func pageContent(_ page: WelcomePage) -> some View {
        switch page.kind {
        case .intro, .done:
            EmptyView()
        case .shortcut:
            ShortcutStepContent(hotkeys: hotkeys, showsExplanation: false)
                .padding(.top, 16)
        case .plugin(let step):
            step.makeView()
                // A new identity per step, so a plugin view's onAppear/onDisappear run for each page.
                .id(step.id)
                .padding(.top, 12)
        }
    }
}

/// The single column's footer: Skip (and Back after the first page) as plain secondary text on the left, the
/// prototype's primary button on the right.
struct WelcomeColumnFooter: View {
    let flow: WelcomeFlow
    var openMainWindow: () -> Void = {}

    var body: some View {
        if let footer = WelcomeFooter(flow: flow) {
            HStack(spacing: 4) {
                if footer.showsSkip {
                    Button {
                        footer.performSkip(flow)
                    } label: {
                        secondaryLabel(Text("Skip", comment: "Welcome screen button that skips a step"))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help(
                        Text(
                            "Skip this step. You can change it later in Settings.",
                            comment: "Welcome screen: help of the Skip button"))
                }
                if footer.showsBack {
                    Button {
                        flow.back()
                    } label: {
                        secondaryLabel(Text("Back", comment: "Welcome screen button that shows the previous step"))
                    }
                    .buttonStyle(.plain)
                    .disabled(!footer.isBackEnabled)
                }
                Spacer()
                Button {
                    footer.performPrimary(flow, openMainWindow: openMainWindow)
                } label: {
                    // The prototype's `.btn` is 12 x 5 pt around a 19 pt line; the style adds 10 x 3.
                    Text(footer.primaryTitle)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                }
                .buttonStyle(LintelPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    private func secondaryLabel(_ text: Text) -> some View {
        text
            .fontWeight(.semibold)
            .foregroundStyle(LintelBrand.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
    }
}
