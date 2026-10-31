import AppKit
import PounceKit
import SwiftUI

/// One page of the welcome screen.
struct WelcomePage: Identifiable {
    enum Kind {
        /// What Pounce is and which steps follow; shown on the very first launch only.
        case intro
        /// The Shortcut step (Q10, spec step 1.2b).
        case shortcut
        /// A plugin's `onboardingSteps` entry.
        case plugin(OnboardingStep)
    }

    static let introID = "intro"
    static let shortcutID = "shortcut"

    let kind: Kind

    var id: String {
        switch kind {
        case .intro: Self.introID
        case .shortcut: Self.shortcutID
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
        }
    }

    var symbolName: String {
        switch kind {
        case .intro: "pawprint"
        case .shortcut: "keyboard"
        case .plugin(let step): step.symbolName
        }
    }

    /// Whether the page can be skipped (the intro has nothing to skip).
    var isSkippable: Bool {
        if case .intro = kind { return false }
        return true
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

/// The welcome screen (spec step 4.2): one window that combines the Shortcut step with the enabled
/// plugins' `onboardingSteps`, with a step list, Back, Skip and Continue. Every step can be skipped.
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

    /// False in QA mode: the window is ordered front without activating Pounce.
    var activatesApp = true

    init(hotkeys: HotkeyService, settings: AppSettings, pluginSteps: @escaping () -> [OnboardingStep] = { [] }) {
        self.hotkeys = hotkeys
        self.settings = settings
        self.pluginSteps = pluginSteps
    }

    var isVisible: Bool { window?.isVisible ?? false }

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
        return pages
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
        let pages =
            [WelcomePage(kind: .intro), WelcomePage(kind: .shortcut)]
            + pluginSteps().map { WelcomePage(kind: .plugin($0)) }
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
        let view = WelcomeView(flow: flow, hotkeys: hotkeys, upcoming: pages)
        present(AnyView(view))
    }

    private func finish(_ page: WelcomePage, skipped: Bool) {
        switch page.kind {
        case .intro:
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
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        if let window {
            window.contentViewController = controller
            return
        }
        let window = ShellWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Welcome to Pounce", comment: "Onboarding window title")
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

/// The welcome window: the step list on the left, the current page with its title on the right, and
/// Back, Skip and Continue (Done on the last page) at the bottom.
struct WelcomeView: View {
    let flow: WelcomeFlow
    let hotkeys: HotkeyService
    /// Every page of this session, for the introduction's list.
    let upcoming: [WelcomePage]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            WelcomeStepList(flow: flow)
                .frame(width: 190)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                if let page = flow.current {
                    WelcomePageHeader(page: page)
                    pageContent(page)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                WelcomeButtons(flow: flow)
            }
            .padding(24)
            .frame(width: 500)
            .frame(minHeight: 380, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func pageContent(_ page: WelcomePage) -> some View {
        switch page.kind {
        case .intro:
            WelcomeIntroView(pages: upcoming.filter { $0.id != WelcomePage.introID })
        case .shortcut:
            ShortcutStepContent(hotkeys: hotkeys)
        case .plugin(let step):
            step.makeView()
                // A new identity per step, so a plugin view's onAppear/onDisappear run for each page.
                .id(step.id)
        }
    }
}

/// The step list: done steps have a checkmark, the current one an arrow and bold text, so the state
/// never depends on colour.
struct WelcomeStepList: View {
    let flow: WelcomeFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(flow.pages.enumerated()), id: \.element.id) { index, page in
                let isCurrent = index == flow.index
                let isDone = flow.finishedPageIDs.contains(page.id)
                HStack(spacing: 8) {
                    Image(
                        systemName: isDone
                            ? "checkmark.circle.fill" : (isCurrent ? "arrow.right.circle.fill" : "circle")
                    )
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                    Text(page.title)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    Text(
                        "Step \(index + 1) of \(flow.pages.count): \(page.title)",
                        comment: "Welcome screen: VoiceOver announcement of the current step")
                )
                .accessibilityValue(stateText(isCurrent: isCurrent, isDone: isDone))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Steps", comment: "Welcome screen: accessibility label of the step list"))
    }

    private func stateText(isCurrent: Bool, isDone: Bool) -> Text {
        if isCurrent {
            Text("Current", comment: "Welcome screen: state of the step on screen")
        } else if isDone {
            Text("Done", comment: "Welcome screen: state of a finished step")
        } else {
            Text("Not started", comment: "Welcome screen: state of a step not reached yet")
        }
    }
}

struct WelcomePageHeader: View {
    let page: WelcomePage

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: page.symbolName)
                .symbolRenderingMode(.hierarchical)
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(page.title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        }
    }
}

struct WelcomeButtons: View {
    let flow: WelcomeFlow

    var body: some View {
        HStack {
            Button {
                flow.back()
            } label: {
                Text("Back", comment: "Welcome screen button that shows the previous step")
            }
            .disabled(flow.isFirst)
            Spacer()
            if flow.current?.isSkippable == true {
                Button {
                    flow.advance(skipping: true)
                } label: {
                    Text("Skip", comment: "Welcome screen button that skips a step")
                }
                .keyboardShortcut(.cancelAction)
                .help(
                    Text(
                        "Skip this step. You can change it later in Settings.",
                        comment: "Welcome screen: help of the Skip button"))
            }
            Button {
                flow.advance()
            } label: {
                continueLabel
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var continueLabel: some View {
        if case .intro? = flow.current?.kind {
            Text("Get Started", comment: "Welcome screen button on the first page")
        } else if case .shortcut? = flow.current?.kind {
            Text("Use This Shortcut", comment: "Onboarding button that confirms the shortcut")
        } else if flow.isLast {
            Text("Done", comment: "Onboarding button on the last step")
        } else {
            Text("Continue", comment: "Onboarding button that goes to the next step")
        }
    }
}

/// The first page: what Pounce is, and the steps that follow.
struct WelcomeIntroView: View {
    let pages: [WelcomePage]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "Pounce opens with a shortcut from anywhere and lives in the menu bar. The next steps set it up; you can skip any of them and change everything later in Settings.",
                comment: "Welcome screen introduction"
            )
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pages) { page in
                    Label {
                        Text(page.title)
                    } icon: {
                        Image(systemName: page.symbolName)
                            .symbolRenderingMode(.hierarchical)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Steps", comment: "Welcome screen: accessibility label of the step list"))
        }
    }
}

/// The Shortcut page: a recorder prefilled with the default shortcut (⌘Space, or ⌃⌥Space while
/// Spotlight holds ⌘Space) and, when Spotlight holds it, how to free it. "Use This Shortcut" keeps what
/// the recorder shows; "Skip" keeps the automatic default (Q10).
struct ShortcutStepContent: View {
    let hotkeys: HotkeyService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "Press this shortcut anywhere to open Pounce. Keep the suggested one or record your own.",
                comment: "Onboarding step explanation"
            )
            .fixedSize(horizontal: false, vertical: true)
            LabeledContent {
                MainShortcutRecorder(hotkeys: hotkeys)
            } label: {
                Text("Open Pounce", comment: "Settings label of the main shortcut")
            }
            if hotkeys.spotlightHoldsCommandSpace {
                GroupBox {
                    SpotlightShortcutBanner()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("You can change it later in Settings → General.", comment: "Onboarding hint")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
