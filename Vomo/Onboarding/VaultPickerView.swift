import SwiftUI

struct VaultPickerView: View {
    @Environment(VaultManager.self) var vault
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "book.closed.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color.obsidianPurple)

            VStack(spacing: 8) {
                Text("Vomo")
                    .font(.largeTitle.bold())
                Text("Your Obsidian vault, by voice")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 16) {
                Button {
                    showPicker = true
                } label: {
                    Label("Open Vault Folder", systemImage: "folder.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.obsidianPurple)

                Text("Select your Obsidian vault folder in iCloud Drive or on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    vault.createSampleVault()
                } label: {
                    Label("Try Sample Vault", systemImage: "doc.text.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(Color.obsidianPurple)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker { url in
                vault.saveBookmark(for: url)
            }
        }
    }
}
