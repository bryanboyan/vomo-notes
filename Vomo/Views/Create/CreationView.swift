import SwiftUI

// MARK: - Text Creation View

/// Text editor for typing a note, with unused transcription picker
struct TextCreationView: View {
    @Environment(VaultManager.self) var vault
    @Environment(\.dismiss) private var dismiss

    @State private var noteText = ""
    @State private var selectedFolder = ""
    @State private var isDiaryFolder = false
    @State private var showFolderPicker = false
    @State private var isSaving = false
    @State private var showSaveError = false

    // Transcription picker
    @State private var unusedTranscriptions: [TranscriptionFileInfo] = []
    @State private var showTranscriptions = false
    @State private var includedPaths: [String] = []

    @FocusState private var isTextFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
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

                Spacer()

                Button("Cancel") { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)

                Button {
                    saveNote()
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
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            // Unused transcriptions banner
            if !unusedTranscriptions.isEmpty {
                transcriptionBanner
            }

            TextEditor(text: $noteText)
                .focused($isTextFocused)
                .font(.body)
                .padding(.horizontal, 12)
                .scrollContentBackground(.hidden)
        }
        .background(Color(.systemBackground))
        .onAppear {
            resolveDefaultFolder()
            scanUnusedTranscriptions()
            isTextFocused = true
        }
        .alert("Save Failed", isPresented: $showSaveError) {
            Button("OK") { }
        } message: {
            Text("Could not save the note. The file may already exist.")
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerSheet(vault: vault, selectedFolder: $selectedFolder, isDiaryFolder: $isDiaryFolder, showPicker: $showFolderPicker)
        }
    }

    // MARK: - Transcription Banner

    @ViewBuilder
    private var transcriptionBanner: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showTranscriptions.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.caption)
                        .foregroundStyle(Color.obsidianPurple)
                    Text("\(unusedTranscriptions.count) unused transcription\(unusedTranscriptions.count == 1 ? "" : "s")")
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: showTranscriptions ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.obsidianPurple.opacity(0.06))
            }
            .buttonStyle(.plain)

            if showTranscriptions {
                VStack(spacing: 0) {
                    ForEach(Array(unusedTranscriptions.enumerated()), id: \.element.id) { index, info in
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                unusedTranscriptions[index].selected.toggle()
                            } label: {
                                Image(systemName: info.selected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(info.selected ? Color.obsidianPurple : Color.gray.opacity(0.4))
                                    .font(.body)
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: info.type == "quick" ? "mic" : "waveform")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Text(info.date.relativeFormatted)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(info.preview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    }

                    if unusedTranscriptions.contains(where: \.selected) {
                        Button {
                            includeSelected()
                        } label: {
                            Text("Include Selected")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.obsidianPurple, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))

                Divider()
            }
        }
    }

    // MARK: - Transcription Helpers

    private func scanUnusedTranscriptions() {
        let transcriptionFiles = vault.files.filter {
            let folder = SettingsManager.shared.transcriptionFolder
            return $0.relativePath.hasPrefix(folder + "/") && $0.relativePath.hasSuffix(".md")
        }

        unusedTranscriptions = transcriptionFiles.compactMap { file in
            let content = vault.loadContent(for: file)
            guard content.contains("saved: false") else { return nil }
            let body = TranscriptionFileInfo.extractBody(from: content)
            let preview = String(body.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
            let type = content.contains("type: quick") ? "quick" : "voice"
            return TranscriptionFileInfo(
                id: file.relativePath,
                date: file.createdDate,
                type: type,
                preview: preview.isEmpty ? "(empty transcription)" : preview
            )
        }
        .sorted { $0.date > $1.date }
    }

    private func includeSelected() {
        for info in unusedTranscriptions where info.selected {
            // Load full body
            if let file = vault.files.first(where: { $0.relativePath == info.id }) {
                let content = vault.loadContent(for: file)
                let body = TranscriptionFileInfo.extractBody(from: content)
                if !body.isEmpty {
                    if !noteText.isEmpty { noteText += "\n\n" }
                    noteText += body
                    includedPaths.append(info.id)
                }
            }
        }
        unusedTranscriptions.removeAll { $0.selected }
        if unusedTranscriptions.isEmpty {
            showTranscriptions = false
        }
    }

    // MARK: - Save

    private func saveNote() {
        let content = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        isSaving = true
        let filename = resolvedFilename(from: content, isDiary: isDiaryFolder, vault: vault)
        if vault.createFile(name: filename, folderPath: selectedFolder, content: content) != nil {
            SettingsManager.shared.creationDefaultFolder = selectedFolder
            // Mark included transcriptions as saved
            let noteTitle = content.components(separatedBy: .newlines).first?
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces) ?? ""
            for path in includedPaths {
                markTranscriptionSaved(path: path, title: noteTitle)
            }
            dismiss()
        } else {
            isSaving = false
            showSaveError = true
        }
    }

    private func markTranscriptionSaved(path: String, title: String) {
        guard let vaultURL = vault.vaultURL else { return }
        let fileURL = vaultURL.appendingPathComponent(path)

        let needsAccess = !vault.isLocalPath
        if needsAccess { guard fileURL.startAccessingSecurityScopedResource() else { return } }
        defer { if needsAccess { fileURL.stopAccessingSecurityScopedResource() } }

        guard var content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        content = content.replacingOccurrences(of: "saved: false", with: "saved: true")
        let safeTitle = title.replacingOccurrences(of: "\"", with: "'")
        content = content.replacingOccurrences(of: "title: \"\"", with: "title: \"\(safeTitle)\"")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
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
}

/// Metadata for an unused transcription file
struct TranscriptionFileInfo: Identifiable {
    let id: String  // relative path
    let date: Date
    let type: String  // "quick" or "voice"
    let preview: String
    var selected: Bool = false

    /// Extract the body content (after frontmatter) from a markdown file
    static func extractBody(from content: String) -> String {
        guard content.hasPrefix("---") else { return content }
        let afterFirst = content.dropFirst(3)
        guard let endRange = afterFirst.range(of: "---") else { return content }
        return String(afterFirst[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Shared Components

struct FolderPickerSheet: View {
    let vault: VaultManager
    @Binding var selectedFolder: String
    @Binding var isDiaryFolder: Bool
    @Binding var showPicker: Bool

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selectedFolder = ""
                    isDiaryFolder = false
                    showPicker = false
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text("Vault Root")
                        Spacer()
                        if selectedFolder.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.obsidianPurple)
                        }
                    }
                }
                .foregroundStyle(.primary)

                if let tree = vault.folderTree {
                    ForEach(tree.children) { folder in
                        folderRow(folder, depth: 0)
                    }
                }
            }
            .navigationTitle("Save Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func folderRow(_ folder: VaultFolder, depth: Int) -> AnyView {
        AnyView(
            Group {
                Button {
                    selectedFolder = folder.id
                    isDiaryFolder = isDiaryLike(folder.id)
                    showPicker = false
                } label: {
                    HStack {
                        ForEach(0..<depth, id: \.self) { _ in
                            Spacer().frame(width: 16)
                        }
                        Image(systemName: "folder")
                            .foregroundStyle(Color.obsidianPurple)
                        Text(folder.name)
                        Spacer()
                        if selectedFolder == folder.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.obsidianPurple)
                        }
                    }
                }
                .foregroundStyle(.primary)

                ForEach(folder.children) { child in
                    folderRow(child, depth: depth + 1)
                }
            }
        )
    }
}

// MARK: - Shared Helpers

func isDiaryLike(_ folder: String) -> Bool {
    let name = folder.split(separator: "/").last.map(String.init)?.lowercased() ?? folder.lowercased()
    let diaryNames = Set(["daily notes", "diary", "journal", "daily", "dailies"])
    return diaryNames.contains(name)
}

func resolvedFilename(from content: String, isDiary: Bool, vault: VaultManager) -> String {
    if isDiary {
        return vault.todayDiaryFilename()
    }
    let firstLine = content.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: .newlines).first ?? ""
    let cleaned = firstLine
        .replacingOccurrences(of: "#", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    if cleaned.count >= 3 {
        let safe = cleaned.prefix(60)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return safe + ".md"
    }

    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd-HHmm"
    return fmt.string(from: Date()) + ".md"
}
