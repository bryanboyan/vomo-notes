import SwiftUI
import UIKit

/// Shared state object giving NoteEditorView direct access to the UITextView.
/// Not @Observable — reads do NOT trigger SwiftUI re-renders.
class TextEditorState {
    weak var textView: UITextView?

    var currentText: String {
        textView?.text ?? ""
    }

    var currentSelectedRange: NSRange {
        textView?.selectedRange ?? .init(location: 0, length: 0)
    }
}

/// UITextView wrapper that exposes cursor position / selection range
/// so MarkdownToolbar can insert at the right place.
struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    var isFocused: Bool
    var onFocusChange: ((Bool) -> Void)?
    var editorState: TextEditorState?
    var onTextChange: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.systemFont(ofSize: 17, weight: .regular).withDesign(.serif)
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        tv.textContainer.lineFragmentPadding = 0
        tv.backgroundColor = .clear
        tv.autocapitalizationType = .sentences
        tv.autocorrectionType = .default
        tv.isScrollEnabled = false
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        tv.typingAttributes = [
            .font: tv.font!,
            .foregroundColor: UIColor.label,
            .paragraphStyle: style,
        ]

        context.coordinator.textView = tv
        editorState?.textView = tv
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // When a pending UIKit update exists (debounced text sync in progress),
        // skip overwriting the text view — but still handle focus/selection.
        let skipTextSync = context.coordinator.pendingUIKitUpdate
        if skipTextSync {
            context.coordinator.pendingUIKitUpdate = false
        }

        if !skipTextSync && tv.text != text {
            let prevRange = tv.selectedRange
            tv.text = text
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 6
            let fullRange = NSRange(location: 0, length: (tv.text as NSString).length)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: tv.font ?? UIFont.systemFont(ofSize: 17),
                .foregroundColor: UIColor.label,
                .paragraphStyle: style,
            ]
            tv.textStorage.setAttributes(attrs, range: fullRange)
            let maxLen = (tv.text as NSString).length
            let loc = min(prevRange.location, maxLen)
            let len = min(prevRange.length, maxLen - loc)
            tv.selectedRange = NSRange(location: loc, length: len)
        }

        if tv.selectedRange != selectedRange {
            let maxLen = (tv.text as NSString).length
            let loc = min(selectedRange.location, maxLen)
            let len = min(selectedRange.length, maxLen - loc)
            tv.selectedRange = NSRange(location: loc, length: len)
        }

        if isFocused && !tv.isFirstResponder {
            DispatchQueue.main.async { tv.becomeFirstResponder() }
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: UITextView?
        var pendingUIKitUpdate = false
        private var skipNextSelectionSync = false
        private var syncWorkItem: DispatchWorkItem?

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            skipNextSelectionSync = true
            parent.onTextChange?()
            syncWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.pendingUIKitUpdate = true
                self.parent.text = tv.text
                self.parent.selectedRange = tv.selectedRange
            }
            syncWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if skipNextSelectionSync {
                skipNextSelectionSync = false
                return
            }
            parent.selectedRange = textView.selectedRange
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            syncWorkItem?.cancel()
            syncWorkItem = nil
            parent.text = textView.text
            parent.selectedRange = textView.selectedRange
            parent.onFocusChange?(false)
        }

        func flushSync() {
            syncWorkItem?.cancel()
            syncWorkItem = nil
            guard let tv = textView else { return }
            pendingUIKitUpdate = true
            parent.text = tv.text
            parent.selectedRange = tv.selectedRange
        }
    }
}

private extension UIFont {
    func withDesign(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
        guard let descriptor = fontDescriptor.withDesign(design) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
