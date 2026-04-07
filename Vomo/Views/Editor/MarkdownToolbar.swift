import SwiftUI

/// Markdown formatting toolbar displayed above the keyboard.
struct MarkdownToolbar: View {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    var onBeforeAction: (() -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                toolbarButton("Heading", icon: "number") {
                    onBeforeAction?()
                    insertMarkdown(prefix: "# ")
                }
                toolbarButton("Bold", icon: "bold") {
                    onBeforeAction?()
                    insertMarkdown(prefix: "**", suffix: "**")
                }
                toolbarButton("Italic", icon: "italic") {
                    onBeforeAction?()
                    insertMarkdown(prefix: "_", suffix: "_")
                }
                toolbarButton("Strikethrough", icon: "strikethrough") {
                    onBeforeAction?()
                    insertMarkdown(prefix: "~~", suffix: "~~")
                }

                Divider().frame(height: 20).padding(.horizontal, 4)

                toolbarButton("Bullet List", icon: "list.bullet") {
                    onBeforeAction?()
                    insertMarkdown(prefix: "- ")
                }
                toolbarButton("Numbered List", icon: "list.number") {
                    onBeforeAction?()
                    insertMarkdown(prefix: "1. ")
                }
                toolbarButton("Checklist", icon: "checklist") {
                    onBeforeAction?()
                    insertMarkdown(prefix: "- [ ] ")
                }

                Divider().frame(height: 20).padding(.horizontal, 4)

                toolbarButton("Link", icon: "link") {
                    onBeforeAction?()
                    insertMarkdown(prefix: "[", suffix: "](url)")
                }
                toolbarButton("Wiki Link", icon: "link.badge.plus") {
                    onBeforeAction?()
                    insertMarkdown(prefix: "[[", suffix: "]]")
                }
                toolbarButton("Code", icon: "chevron.left.forwardslash.chevron.right") {
                    onBeforeAction?()
                    insertMarkdown(prefix: "`", suffix: "`")
                }
                toolbarButton("Quote", icon: "text.quote") {
                    onBeforeAction?()
                    insertMarkdown(prefix: "> ")
                }
                toolbarButton("Tag", icon: "tag") {
                    onBeforeAction?()
                    insertMarkdown(prefix: "#")
                }

                Divider().frame(height: 20).padding(.horizontal, 4)

                toolbarButton("Dismiss Keyboard", icon: "keyboard.chevron.compact.down") {
                    hideKeyboard()
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 44)
        .background(.bar)
    }

    private func toolbarButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: - Text Manipulation

    /// Insert markdown at the current cursor position.
    /// If text is selected, wraps the selection. Otherwise inserts placeholder.
    private func insertMarkdown(prefix: String, suffix: String? = nil) {
        let nsText = text as NSString
        let maxLen = nsText.length
        // Clamp range to valid bounds
        let loc = min(selectedRange.location, maxLen)
        let len = min(selectedRange.length, maxLen - loc)
        let range = NSRange(location: loc, length: len)

        let isLineLevelPrefix = ["# ", "- ", "1. ", "- [ ] ", "> "].contains(prefix)

        if isLineLevelPrefix {
            // Line-level: ensure we're on a new line, insert at cursor
            var insert = prefix
            if range.location > 0 {
                let charBefore = nsText.substring(with: NSRange(location: range.location - 1, length: 1))
                if charBefore != "\n" {
                    insert = "\n" + prefix
                }
            }
            text = nsText.replacingCharacters(in: range, with: insert)
            let newCursor = range.location + (insert as NSString).length
            selectedRange = NSRange(location: newCursor, length: 0)
        } else if let suffix {
            let selected = nsText.substring(with: range)
            if selected.isEmpty {
                // No selection: insert prefix + "text" + suffix, select "text"
                let placeholder = "text"
                let insertion = prefix + placeholder + suffix
                text = nsText.replacingCharacters(in: range, with: insertion)
                let selectStart = range.location + (prefix as NSString).length
                selectedRange = NSRange(location: selectStart, length: (placeholder as NSString).length)
            } else {
                // Wrap selected text
                let wrapped = prefix + selected + suffix
                text = nsText.replacingCharacters(in: range, with: wrapped)
                // Place cursor after the closing suffix
                let newCursor = range.location + (wrapped as NSString).length
                selectedRange = NSRange(location: newCursor, length: 0)
            }
        } else {
            // Simple prefix (e.g. #tag)
            text = nsText.replacingCharacters(in: range, with: prefix)
            let newCursor = range.location + (prefix as NSString).length
            selectedRange = NSRange(location: newCursor, length: 0)
        }
    }
}
