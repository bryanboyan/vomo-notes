import SwiftUI

struct BrowseTab: View {
    @Environment(VaultManager.self) var vault
    @Binding var path: [VaultFile]

    var body: some View {
        NavigationStack(path: $path) {
            BrowseView(navigationPath: $path)
                .navigationDestination(for: VaultFile.self) { file in
                    ReaderView(file: file, navigationPath: $path)
                }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "obsidian", url.host() == "open" else { return .systemAction }
            let name = url.pathComponents.dropFirst().joined(separator: "/")
                .removingPercentEncoding ?? ""
            if let file = vault.resolveWikiLink(name) {
                vault.markAsRecent(file)
                path.append(file)
                return .handled
            }
            return .systemAction
        })
    }
}
