import SwiftUI

/// Read-only prompt preview in settings — shows description, status, and prompt content.
/// Tap "Edit" to open the prompt file in a full-screen editor.
struct PromptDetailView: View {
    let definition: PromptDefinition
    @Environment(VaultManager.self) var vault
    @State private var promptText: String = ""
    @State private var isCustom = false
    @State private var showEditor = false

    var body: some View {
        List {
            Section {
                Text(definition.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Stored at \(PromptManager.relativePath(for: definition.id)) in your vault. You can also edit this file in your cloud storage remotely.")
                    .font(.caption2)
            }

            Section {
                HStack {
                    Text("Status")
                        .font(.subheadline)
                    Spacer()
                    Text(isCustom ? "Customized" : "Default")
                        .font(.caption)
                        .foregroundStyle(isCustom ? .blue : .secondary)
                }

                if !definition.variables.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Variables")
                            .font(.subheadline)
                        Text(definition.variables.map { "{{\($0)}}" }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Prompt") {
                Text(promptText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 150)
                    .textSelection(.enabled)
            }

            Section {
                Button {
                    // Ensure override file exists before editing
                    PromptManager.createOverrideFile(definition.id, vaultURL: vault.vaultURL)
                    showEditor = true
                } label: {
                    Label("Edit Prompt", systemImage: "pencil")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                if isCustom {
                    Button("Reset to Default", role: .destructive) {
                        resetToDefault()
                    }
                    .font(.subheadline)
                }
            } footer: {
                Text("Changes take effect immediately for new conversations.")
                    .font(.caption2)
            }
        }
        .navigationTitle(definition.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .fullScreenCover(isPresented: $showEditor) {
            reload()
        } content: {
            PromptEditorView(definition: definition)
        }
    }

    private func reload() {
        isCustom = PromptManager.isCustomized(definition.id, vaultURL: vault.vaultURL)
        promptText = PromptManager.resolve(definition.id, vaultURL: vault.vaultURL)
    }

    private func resetToDefault() {
        guard let fileURL = PromptManager.fileURL(for: definition.id, vaultURL: vault.vaultURL) else { return }
        let vaultURL = vault.vaultURL
        let needsAccess = vaultURL != nil && !vaultURL!.path.hasPrefix("/var/") && !vaultURL!.path.hasPrefix("/Users/")
        if needsAccess { _ = vaultURL!.startAccessingSecurityScopedResource() }
        defer { if needsAccess { vaultURL!.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.removeItem(at: fileURL)
        reload()
    }
}

// MARK: - Full-Screen Prompt Editor

struct PromptEditorView: View {
    let definition: PromptDefinition
    @Environment(VaultManager.self) private var vault
    @Environment(\.dismiss) private var dismiss
    @State private var editableText: String = ""
    @State private var hasChanges = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $editableText)
                .font(.system(.body, design: .monospaced))
                .focused($isFocused)
                .padding(.horizontal, 8)
                .onChange(of: editableText) { hasChanges = true }
                .navigationTitle(definition.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") {
                            PromptManager.saveOverrideContent(definition.id, content: editableText, vaultURL: vault.vaultURL)
                            dismiss()
                        }
                        .fontWeight(.semibold)
                        .disabled(!hasChanges)
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { hideKeyboard() }
                            .font(.subheadline.bold())
                    }
                }
                .onAppear {
                    editableText = PromptManager.resolve(definition.id, vaultURL: vault.vaultURL)
                    hasChanges = false
                    isFocused = true
                }
        }
    }
}
