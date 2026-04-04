import SwiftUI

/// iA Writer-inspired distraction-free note editor.
/// Supports creating new notes and editing existing ones.
struct NoteEditorView: View {
    @Environment(VaultManager.self) var vault
    @Environment(\.dismiss) private var dismiss

    /// Pass an existing file to edit; nil for new note creation.
    var existingFile: VaultFile?
    /// When true, operates as a persistent tab (no dismiss, resets after save)
    var isTabMode = false

    @State private var titleText = ""
    @State private var bodyText = ""
    @State private var properties: [EditableProperty] = []
    @State private var selectedFolder = ""
    @State private var isDiaryFolder = false
    @State private var showFolderPicker = false
    @State private var isSaving = false
    @State private var showSaveError = false
    @State private var hasUnsavedChanges = false
    @State private var showDiscardAlert = false
    @State private var showProperties = false
    @State private var wordCount = 0
    @State private var wordCountTask: Task<Void, Never>?
    @State private var bodySelectedRange = NSRange(location: 0, length: 0)
    @State private var bodyIsFocused = false
    @State private var editorState = TextEditorState()

    @FocusState private var titleFocused: Bool

    private var isNewNote: Bool { existingFile == nil }
    private var isEditing: Bool { existingFile != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editorContent
                MarkdownToolbar(text: $bodyText, selectedRange: $bodySelectedRange, onBeforeAction: {
                    bodyText = editorState.currentText
                    bodySelectedRange = editorState.currentSelectedRange
                })
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
            .onAppear(perform: loadContent)
            .onChange(of: bodyText) { _, _ in
                updateWordCount()
            }
            .onChange(of: titleText) { _, _ in hasUnsavedChanges = true }
            .onChange(of: properties) { _, _ in hasUnsavedChanges = true }
            .alert("Save Failed", isPresented: $showSaveError) {
                Button("OK") { }
            } message: {
                Text("Could not save the note. The file may already exist.")
            }
            .alert("Discard Changes?", isPresented: $showDiscardAlert) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) { }
            } message: {
                Text("You have unsaved changes that will be lost.")
            }
            .sheet(isPresented: $showFolderPicker) {
                FolderPickerSheet(
                    vault: vault,
                    selectedFolder: $selectedFolder,
                    isDiaryFolder: $isDiaryFolder,
                    showPicker: $showFolderPicker
                )
            }
        }
    }

    // MARK: - Editor Content

    private var editorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Folder selector (new notes only)
                if isNewNote {
                    folderSelector
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }

                // Property editor
                if showProperties || !properties.isEmpty {
                    PropertyEditorView(properties: $properties)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                // Title field
                TextField("Title", text: $titleText, axis: .vertical)
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                    .focused($titleFocused)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                    .onSubmit {
                        bodyIsFocused = true
                    }

                // Subtle divider
                Rectangle()
                    .fill(Color.obsidianPurple.opacity(0.2))
                    .frame(height: 1)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                // Body editor
                MarkdownTextView(
                    text: $bodyText,
                    selectedRange: $bodySelectedRange,
                    isFocused: bodyIsFocused,
                    onFocusChange: { bodyIsFocused = $0 },
                    editorState: editorState,
                    onTextChange: {
                        hasUnsavedChanges = true
                    }
                )
                .frame(maxWidth: .infinity, minHeight: 400)

                Spacer(minLength: 60)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Folder Selector

    private var folderSelector: some View {
        Button {
            showFolderPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption)
                Text(selectedFolder.isEmpty ? "Vault Root" : selectedFolder)
                    .font(.subheadline)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(Color.obsidianPurple)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if !isTabMode {
                Button {
                    if hasUnsavedChanges {
                        showDiscardAlert = true
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(isNewNote ? "Cancel" : "Done")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }

        ToolbarItem(placement: .principal) {
            // Word count indicator
            if wordCount > 0 {
                Text("\(wordCount) words")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            // Toggle properties
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showProperties.toggle()
                }
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(showProperties || !properties.isEmpty ? Color.obsidianPurple : .secondary)
            }

            // Save button
            Button {
                save()
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Save")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.obsidianPurple, in: Capsule())
                }
            }
            .disabled(!canSave)
        }
    }

    private var canSave: Bool {
        let hasTitle = !titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBody = !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasTitle || hasBody) && !isSaving
    }

    // MARK: - Load Content

    private func loadContent() {
        if let file = existingFile {
            // Edit mode: parse existing content
            let raw = vault.loadContent(for: file)
            let (frontmatter, body) = MarkdownParser.extractFrontmatter(raw)

            if let fm = frontmatter {
                properties = [EditableProperty].fromFrontmatter(fm)
                showProperties = !properties.isEmpty
            }

            // Extract title from first heading or use filename
            let lines = body.components(separatedBy: "\n")
            var titleLine = ""
            var bodyLines: [String] = []
            var foundTitle = false

            for line in lines {
                if !foundTitle && line.hasPrefix("# ") {
                    titleLine = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    foundTitle = true
                } else {
                    bodyLines.append(line)
                }
            }

            if foundTitle {
                titleText = titleLine
                bodyText = bodyLines.joined(separator: "\n")
                    .trimmingCharacters(in: .newlines)
            } else {
                titleText = file.title
                bodyText = body.trimmingCharacters(in: .newlines)
            }

            updateWordCount()
            hasUnsavedChanges = false
            // Focus body when editing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                bodyIsFocused = true
            }
        } else {
            // New note mode
            resolveDefaultFolder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                titleFocused = true
            }
        }
    }

    // MARK: - Save

    private func save() {
        isSaving = true
        bodyText = editorState.currentText

        let content = buildMarkdownContent()

        if let file = existingFile {
            // Update existing file
            vault.updateFileContent(file, newContent: content)
            hasUnsavedChanges = false
            isSaving = false
            dismiss()
        } else {
            // Create new file
            let filename = resolveFilename()
            if vault.createFile(name: filename, folderPath: selectedFolder, content: content) != nil {
                SettingsManager.shared.creationDefaultFolder = selectedFolder
                if isTabMode {
                    resetEditor()
                } else {
                    dismiss()
                }
            } else {
                isSaving = false
                showSaveError = true
            }
        }
    }

    private func resetEditor() {
        titleText = ""
        bodyText = ""
        properties = []
        showProperties = false
        wordCount = 0
        wordCountTask?.cancel()
        wordCountTask = nil
        isSaving = false
        hasUnsavedChanges = false
        resolveDefaultFolder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            titleFocused = true
        }
    }

    private func buildMarkdownContent() -> String {
        var parts: [String] = []

        // Frontmatter
        let fm = properties.toFrontmatter()
        if !fm.isEmpty {
            parts.append(fm)
        }

        // Title as H1
        let trimmedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            parts.append("# \(trimmedTitle)")
        }

        // Body
        let trimmedBody = bodyText.trimmingCharacters(in: .newlines)
        if !trimmedBody.isEmpty {
            parts.append(trimmedBody)
        }

        return parts.joined(separator: "\n\n") + "\n"
    }

    private func resolveFilename() -> String {
        if isDiaryFolder {
            return vault.todayDiaryFilename()
        }

        let trimmedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.count >= 3 {
            let safe = String(trimmedTitle.prefix(60))
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            return safe + ".md"
        }

        // Fallback: first line of body
        let firstLine = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        let cleaned = firstLine
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count >= 3 {
            let safe = String(cleaned.prefix(60))
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            return safe + ".md"
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        return fmt.string(from: Date()) + ".md"
    }

    private func resolveDefaultFolder() {
        let preferred = SettingsManager.shared.creationDefaultFolder
        if !preferred.isEmpty {
            selectedFolder = preferred
            isDiaryFolder = isDiaryLike(preferred)
            return
        }
        if let diary = vault.detectDiaryFolder() {
            selectedFolder = diary
            isDiaryFolder = true
            return
        }
        selectedFolder = ""
        isDiaryFolder = false
    }

    private func updateWordCount() {
        let allText = titleText + " " + bodyText
        let words = allText.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        wordCount = words.count
    }
}
