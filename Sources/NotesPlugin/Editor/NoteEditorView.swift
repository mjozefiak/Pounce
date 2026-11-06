import AppKit
import LintelKit
import LintelUI
import SwiftUI

/// The editor in SwiftUI: the format bar over the Markdown editor (prototype `.fmt` and `.ed`). It takes the buffer
/// as a binding and reports edits through `onEdit`; it does not save (step 4.2 does), and it never shows a
/// control that writes while `isReadOnly` is set (`plugins.notes.readOnly`, or a state the spec makes read-only).
struct NoteEditorSurface<Header: View>: View {
    @Binding var text: String
    let isReadOnly: Bool
    let wrapsLines: Bool
    let onEdit: (NoteEditorEdit) -> Void
    /// Writes a comment on a selection of the buffer (text, selection, the buffer); `true` when it was written.
    /// `nil` turns the Comment button off (a layer that cannot be commented on).
    let onAddComment: ((String, NSRange, String) async -> Bool)?
    /// Where the open comments are in the buffer, and which thread a caret inside one picks (step 5.2).
    let highlights: [CommentHighlight]
    let onSelectThread: ((Int64) -> Void)?
    /// Who wrote each block of the buffer (step 4.3); `nil` shows no author gutter.
    let attribution: (([String]) -> [BlockAttributionInfo])?
    let showsAuthorBars: Bool
    /// The editor gained or lost focus (a save point).
    let onFocusChange: ((Bool) -> Void)?
    let header: Header
    @State private var controller: NoteEditorController
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var draft: CommentDraft?
    #if DEBUG
    /// QA: select this text and open the popover once the editor is on screen (`plugins.notes.qaComments=popover`).
    var qaSelect: String?
    #endif
    @Environment(\.lintelTextSize) private var textSize

    init(
        text: Binding<String>, pasteboard: any PasteboardClient, isReadOnly: Bool = false, wrapsLines: Bool = true,
        onAddComment: ((String, NSRange, String) async -> Bool)? = nil, highlights: [CommentHighlight] = [],
        onSelectThread: ((Int64) -> Void)? = nil, attribution: (([String]) -> [BlockAttributionInfo])? = nil,
        showsAuthorBars: Bool = true, onFocusChange: ((Bool) -> Void)? = nil,
        onEdit: @escaping (NoteEditorEdit) -> Void = { _ in }, @ViewBuilder header: () -> Header
    ) {
        self.highlights = highlights
        self.onSelectThread = onSelectThread
        self.header = header()
        self.onFocusChange = onFocusChange
        self.attribution = attribution
        self.showsAuthorBars = showsAuthorBars
        _text = text
        self.isReadOnly = isReadOnly
        self.wrapsLines = wrapsLines
        self.onAddComment = onAddComment
        self.onEdit = onEdit
        _controller = State(initialValue: NoteEditorController(pasteboard: pasteboard, isReadOnly: isReadOnly))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isReadOnly {
                NoteFormatBar(
                    controller: controller, canComment: onAddComment != nil && selection.length > 0 && draft == nil,
                    onComment: openComment)
            }
            header
            NoteEditorRepresentable(
                controller: controller, text: $text, isReadOnly: isReadOnly, wrapsLines: wrapsLines,
                textSize: textSize, attribution: attribution, showsAuthorBars: showsAuthorBars,
                highlights: highlights, pending: draft?.range, onSelectionChange: selectionChanged,
                onComment: openComment, onFocusChange: onFocusChange, onEdit: onEdit
            )
            .overlay(alignment: .topLeading) {
                if let draft { popover(for: draft) }
            }
            #if DEBUG
            .task(id: qaSelect) {
                guard let qaSelect else { return }
                try? await Task.sleep(for: .milliseconds(400))
                let range = (controller.text as NSString).range(of: qaSelect)
                guard range.location != NSNotFound else { return }
                controller.textView.setSelectedRange(range)
                openComment()
            }
            #endif
        }
    }

    private func selectionChanged(_ range: NSRange) {
        selection = range
        guard range.length == 0, let onSelectThread,
            let hit = highlights.first(where: {
                range.location >= $0.range.location && range.location <= NSMaxRange($0.range)
            })
        else { return }
        onSelectThread(hit.threadID)
    }

    /// ⇧⌘M and the format bar's Comment: the popover for the selected passage (nothing when nothing is selected, or
    /// when the passage cannot be anchored).
    private func openComment() {
        guard onAddComment != nil, draft == nil else { return }
        let range = controller.textView.selectedRange()
        guard range.length > 0, CommentAnchors.make(in: controller.text, range: range) != nil else { return }
        let rect =
            controller.scrollView.flatMap { controller.rect(of: range, in: $0) }
            ?? CGRect(x: 24, y: 24, width: 0, height: 0)
        draft = CommentDraft(range: range, buffer: controller.text, rect: rect)
    }

    private func popover(for draft: CommentDraft) -> some View {
        let width = CommentPopover.width(textSize)
        return GeometryReader { proxy in
            CommentPopover(
                onSubmit: { body in
                    guard let onAddComment else { return false }
                    let written = await onAddComment(body, draft.range, draft.buffer)
                    if written { close() }
                    return written
                }, onCancel: close
            )
            .offset(
                x: min(max(0, draft.rect.minX), max(0, proxy.size.width - width)), y: draft.rect.maxY + 6)
        }
    }

    private func close() {
        draft = nil
        controller.textView.window?.makeFirstResponder(controller.textView)
    }
}

/// The passage the popover comments on, with where to draw it.
struct CommentDraft: Equatable {
    var range: NSRange
    var buffer: String
    var rect: CGRect
}

extension NoteEditorSurface where Header == EmptyView {
    init(
        text: Binding<String>, pasteboard: any PasteboardClient, isReadOnly: Bool = false, wrapsLines: Bool = true,
        onAddComment: ((String, NSRange, String) async -> Bool)? = nil, highlights: [CommentHighlight] = [],
        onSelectThread: ((Int64) -> Void)? = nil, attribution: (([String]) -> [BlockAttributionInfo])? = nil,
        showsAuthorBars: Bool = true, onFocusChange: ((Bool) -> Void)? = nil,
        onEdit: @escaping (NoteEditorEdit) -> Void = { _ in }
    ) {
        self.init(
            text: text, pasteboard: pasteboard, isReadOnly: isReadOnly, wrapsLines: wrapsLines,
            onAddComment: onAddComment, highlights: highlights, onSelectThread: onSelectThread,
            attribution: attribution, showsAuthorBars: showsAuthorBars, onFocusChange: onFocusChange, onEdit: onEdit,
            header: { EmptyView() })
    }
}

/// The scroll view and text view of one `NoteEditorController`.
struct NoteEditorRepresentable: NSViewRepresentable {
    let controller: NoteEditorController
    @Binding var text: String
    let isReadOnly: Bool
    let wrapsLines: Bool
    let textSize: TextSize
    let attribution: (([String]) -> [BlockAttributionInfo])?
    let showsAuthorBars: Bool
    let highlights: [CommentHighlight]
    let pending: NSRange?
    let onSelectionChange: (NSRange) -> Void
    let onComment: () -> Void
    let onFocusChange: ((Bool) -> Void)?
    let onEdit: (NoteEditorEdit) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = controller.textView
        controller.scrollView = scroll
        controller.textView.textContainer?.lineFragmentPadding = 0
        if attribution != nil {
            // The author gutter is the vertical ruler: it scrolls with the text and keeps the text off the bars.
            let ruler = AuthorGutterRuler(scrollView: scroll, client: controller.textView)
            scroll.verticalRulerView = ruler
            scroll.hasVerticalRuler = true
            scroll.rulersVisible = true
            controller.gutter = ruler
            controller.textView.onDraw = { [weak ruler] in ruler?.needsDisplay = true }
        }
        controller.setText(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let scale = textSize.scale
        let hasGutter = attribution != nil
        scroll.contentInsets = NSEdgeInsets(
            top: 6 * scale, left: (hasGutter ? 6 : 5.4 * 12.5 + 6) * scale, bottom: 24 * scale, right: 28 * scale)
        controller.gutter?.textScale = scale
        controller.gutter?.showsBars = showsAuthorBars
        scroll.hasHorizontalScroller = !wrapsLines
        let binding = $text
        controller.onEdit = { edit in
            binding.wrappedValue = edit.text
            onEdit(edit)
        }
        controller.isReadOnly = isReadOnly
        controller.onSelectionChange = onSelectionChange
        controller.textView.commentShortcut = onComment
        if let onFocusChange { controller.onFocusChange = onFocusChange }
        controller.setTextSize(textSize)
        controller.setWrapsLines(wrapsLines)
        if let attribution, controller.attribution == nil { controller.attribution = attribution }
        if controller.text != text { controller.setText(text) }
        controller.setHighlights(highlights, pending: pending)
    }
}

/// The format bar (prototype `.fmt`): paragraph and headings, bold, italic and strikethrough, the list, task and
/// quote prefixes and a link, then the Comment button on the right.
struct NoteFormatBar: View {
    let controller: NoteEditorController
    /// Something is selected that a comment can point at.
    let canComment: Bool
    let onComment: () -> Void
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.groups.indices, id: \.self) { group in
                if group > 0 { separator }
                ForEach(Self.groups[group], id: \.id) { item in button(item) }
            }
            Spacer(minLength: 0)
            commentButton
        }
        .padding(.horizontal, 12 * textSize.scale)
        .frame(height: 33.75 * textSize.scale)
        .background(LintelBrand.fill)
        .overlay(alignment: .bottom) { LintelDivider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Formatting", comment: "Accessibility label of the editor's format bar"))
    }

    private var separator: some View {
        LintelBrand.hairline.frame(width: 1, height: 16.25 * textSize.scale).padding(.horizontal, 6)
    }

    private func button(_ item: Item) -> some View {
        Button {
            controller.perform(item.action)
        } label: {
            item.glyph(textSize)
                .foregroundStyle(LintelBrand.secondaryText)
                .frame(minWidth: 25 * textSize.scale, minHeight: 25 * textSize.scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.label))
        .help(Text(item.label))
    }

    private var commentButton: some View {
        Button {
            onComment()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                Text("Comment", comment: "Format bar: comment on the selected text")
                Text(verbatim: "⇧⌘M").font(textSize.font(.footnote)).foregroundStyle(LintelBrand.secondaryText)
            }
            .font(textSize.font(.callout, weight: .semibold))
            .foregroundStyle(LintelBrand.accentText)
            .padding(.horizontal, 5)
            .frame(minHeight: 25 * textSize.scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(!canComment)
        .accessibilityLabel(Text("Comment", comment: "Format bar: comment on the selected text"))
        .accessibilityHint(
            Text(
                "Select text first. Opens a field for your comment.",
                comment: "Accessibility hint of the format bar's Comment button"))
    }

    struct Item {
        var id: String { String(describing: action) }
        var action: NoteFormatAction
        var label: LocalizedStringResource
        var glyph: @MainActor (TextSize) -> AnyView
    }

    private static func text(_ string: String, _ weight: Font.Weight = .semibold) -> @MainActor (TextSize) -> AnyView {
        { size in AnyView(Text(verbatim: string).font(size.font(.callout, weight: weight.nsWeight))) }
    }

    private static func symbol(_ name: String) -> @MainActor (TextSize) -> AnyView {
        { size in AnyView(Image(systemName: name).font(size.font(.callout, weight: .semibold))) }
    }

    static let groups: [[Item]] = [
        [
            Item(
                action: .paragraph,
                label: LocalizedStringResource("Paragraph", comment: "Format bar: turn the line into a paragraph"),
                glyph: text("¶")),
            Item(
                action: .heading(1),
                label: LocalizedStringResource("Heading 1", comment: "Format bar: heading level 1"), glyph: text("H1")),
            Item(
                action: .heading(2),
                label: LocalizedStringResource("Heading 2", comment: "Format bar: heading level 2"), glyph: text("H2")),
            Item(
                action: .heading(3),
                label: LocalizedStringResource("Heading 3", comment: "Format bar: heading level 3"), glyph: text("H3")),
        ],
        [
            Item(
                action: .bold, label: LocalizedStringResource("Bold", comment: "Format bar: bold"),
                glyph: text("B", .bold)),
            Item(
                action: .italic, label: LocalizedStringResource("Italic", comment: "Format bar: italic"),
                glyph: { size in AnyView(Text(verbatim: "I").font(size.font(.callout, weight: .semibold)).italic()) }),
            Item(
                action: .strike, label: LocalizedStringResource("Strikethrough", comment: "Format bar: strikethrough"),
                glyph: { size in
                    AnyView(Text(verbatim: "S").font(size.font(.callout, weight: .semibold)).strikethrough())
                }),
        ],
        [
            Item(
                action: .bulletList,
                label: LocalizedStringResource("Bulleted list", comment: "Format bar: bulleted list"),
                glyph: symbol("list.bullet")),
            Item(
                action: .taskList, label: LocalizedStringResource("Task list", comment: "Format bar: task list"),
                glyph: symbol("checklist")),
            Item(
                action: .quote, label: LocalizedStringResource("Quote", comment: "Format bar: quote"),
                glyph: symbol("text.quote")),
            Item(
                action: .link, label: LocalizedStringResource("Link", comment: "Format bar: link"),
                glyph: symbol("link")),
        ],
    ]
}

extension Font.Weight {
    fileprivate var nsWeight: NSFont.Weight { self == .bold ? .bold : .semibold }
}
