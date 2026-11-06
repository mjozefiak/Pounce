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
    /// Opens the comment popover; `nil` until comments exist (step 5.2), then the button is disabled.
    let onComment: (() -> Void)?
    let header: Header
    @State private var controller: NoteEditorController
    @Environment(\.lintelTextSize) private var textSize

    init(
        text: Binding<String>, pasteboard: any PasteboardClient, isReadOnly: Bool = false, wrapsLines: Bool = true,
        onComment: (() -> Void)? = nil, onEdit: @escaping (NoteEditorEdit) -> Void = { _ in },
        @ViewBuilder header: () -> Header
    ) {
        self.header = header()
        _text = text
        self.isReadOnly = isReadOnly
        self.wrapsLines = wrapsLines
        self.onComment = onComment
        self.onEdit = onEdit
        _controller = State(initialValue: NoteEditorController(pasteboard: pasteboard, isReadOnly: isReadOnly))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isReadOnly { NoteFormatBar(controller: controller, onComment: onComment) }
            header
            NoteEditorRepresentable(
                controller: controller, text: $text, isReadOnly: isReadOnly, wrapsLines: wrapsLines,
                textSize: textSize, onEdit: onEdit)
        }
    }
}

extension NoteEditorSurface where Header == EmptyView {
    init(
        text: Binding<String>, pasteboard: any PasteboardClient, isReadOnly: Bool = false, wrapsLines: Bool = true,
        onComment: (() -> Void)? = nil, onEdit: @escaping (NoteEditorEdit) -> Void = { _ in }
    ) {
        self.init(
            text: text, pasteboard: pasteboard, isReadOnly: isReadOnly, wrapsLines: wrapsLines, onComment: onComment,
            onEdit: onEdit, header: { EmptyView() })
    }
}

/// The scroll view and text view of one `NoteEditorController`.
struct NoteEditorRepresentable: NSViewRepresentable {
    let controller: NoteEditorController
    @Binding var text: String
    let isReadOnly: Bool
    let wrapsLines: Bool
    let textSize: TextSize
    let onEdit: (NoteEditorEdit) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = controller.textView
        controller.textView.textContainer?.lineFragmentPadding = 0
        controller.setText(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let scale = textSize.scale
        scroll.contentInsets = NSEdgeInsets(
            top: 6 * scale, left: (5.4 * 12.5 + 6) * scale, bottom: 24 * scale, right: 28 * scale)
        scroll.hasHorizontalScroller = !wrapsLines
        let binding = $text
        controller.onEdit = { edit in
            binding.wrappedValue = edit.text
            onEdit(edit)
        }
        controller.isReadOnly = isReadOnly
        controller.setTextSize(textSize)
        controller.setWrapsLines(wrapsLines)
        if controller.text != text { controller.setText(text) }
    }
}

/// The format bar (prototype `.fmt`): paragraph and headings, bold, italic and strikethrough, the list, task and
/// quote prefixes and a link, then the Comment button on the right.
struct NoteFormatBar: View {
    let controller: NoteEditorController
    let onComment: (() -> Void)?
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
            onComment?()
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
        .disabled(onComment == nil)
        .accessibilityLabel(Text("Comment", comment: "Format bar: comment on the selected text"))
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
