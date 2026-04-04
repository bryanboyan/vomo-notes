import SwiftUI

struct CalendarTab: View {
    @Environment(VaultManager.self) var vault
    @Binding var path: [VaultFile]

    var body: some View {
        NavigationStack(path: $path) {
            CalendarView(navigationPath: $path)
                .navigationDestination(for: VaultFile.self) { file in
                    ReaderView(file: file, navigationPath: $path)
                }
        }
        .environment(\.openURL, OpenURLAction { url in
            handleObsidianURL(url)
        })
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
        }
        return .systemAction
    }
}
