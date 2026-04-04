import SwiftUI

struct SearchTab: View {
    @Environment(VaultManager.self) var vault
    @Binding var path: [VaultFile]
    @Binding var pendingFile: VaultFile?

    var body: some View {
        NavigationStack(path: $path) {
            SearchView(
                navigationPath: $path,
                onMicTapped: nil
            )
            .navigationDestination(for: VaultFile.self) { file in
                ReaderView(file: file, navigationPath: $path)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            handleObsidianURL(url)
        })
        .onChange(of: pendingFile) { _, file in
            if let file {
                path = [file]
                pendingFile = nil
            }
        }
    }

    private func handleObsidianURL(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "obsidian" else { return .systemAction }

        if url.host() == "open" {
            let name = url.pathComponents.dropFirst().joined(separator: "/")
                .removingPercentEncoding ?? ""
            if let file = vault.resolveWikiLink(name) {
                vault.markAsRecent(file)
                path.append(file)
                return .handled
            }
        } else if url.host() == "tag" {
            return .handled
        }

        return .systemAction
    }
}

// MARK: - Environment key for voice conflict guard

private struct AgentVoiceActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var agentVoiceActive: Bool {
        get { self[AgentVoiceActiveKey.self] }
        set { self[AgentVoiceActiveKey.self] = newValue }
    }
}
