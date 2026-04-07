import SwiftUI

@main
struct VomoApp: App {
    @State private var vaultManager = VaultManager()
    @State private var favoritesManager = FavoritesManager()
    @State private var dataviewEngine = DataviewEngine()
    @State private var transcriptCache = TranscriptCache()
    private let phoneConnectivity = PhoneConnectivityManager.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        APIKeychain.migrateIfNeeded()
        // All scroll views dismiss keyboard when dragged
        UIScrollView.appearance().keyboardDismissMode = .interactiveWithAccessory
    }

    var body: some Scene {
        WindowGroup {
            if vaultManager.hasVault {
                ContentView()
                    .environment(vaultManager)
                    .environment(favoritesManager)
                    .environment(dataviewEngine)
                    .environment(transcriptCache)
                    .shakeToReport()
                    .task {
                        // Phase 1: Load from cache for instant display
                        await vaultManager.loadFromCache()
                        // Phase 2: Scan vault and download iCloud files
                        await vaultManager.scanVault()
                        // Phase 3: Start periodic background sync
                        vaultManager.startPeriodicSync()
                        // Phase 4: Index vault for Dataview queries
                        await indexVaultForDataview()
                        // Phase 5: Periodic re-indexing (every 65s, offset from vault sync)
                        startDataviewSync()
                        // Phase 6: Connect watch companion
                        phoneConnectivity.vaultManager = vaultManager
                        phoneConnectivity.dataviewEngine = dataviewEngine
                        phoneConnectivity.syncApiKeyToWatch()
                        phoneConnectivity.syncFoldersToWatch()
                        // Phase 7: Upload any pending voice crash reports
                        CrashReporter.shared.uploadPendingReports()
                    }
            } else {
                VaultPickerView()
                    .environment(vaultManager)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if vaultManager.hasVault {
                    vaultManager.startPeriodicSync()
                }
            case .background, .inactive:
                vaultManager.stopPeriodicSync()
            @unknown default:
                break
            }
        }
    }

    private func indexVaultForDataview() async {
        do {
            try dataviewEngine.setup()
        } catch {
            return
        }
        await dataviewEngine.indexFiles(
            vaultManager.files,
            contentLoader: { file in
                vaultManager.loadContent(for: file)
            },
            linkResolver: { name in
                vaultManager.resolveWikiLink(name)?.id
            }
        )
    }

    private func startDataviewSync() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(65))
                guard !Task.isCancelled else { return }
                await dataviewEngine.reindexIfNeeded(
                    vaultManager.files,
                    contentLoader: { file in vaultManager.loadContent(for: file) },
                    linkResolver: { name in vaultManager.resolveWikiLink(name)?.id }
                )
            }
        }
    }
}
