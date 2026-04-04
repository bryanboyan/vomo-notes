import SwiftUI

struct CreateTab: View {
    @Environment(VaultManager.self) var vault

    var body: some View {
        NoteEditorView(isTabMode: true)
            .environment(vault)
    }
}
