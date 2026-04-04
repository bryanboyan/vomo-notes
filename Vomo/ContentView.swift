import SwiftUI

// MARK: - Settings Environment Action

struct ShowSettingsActionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var showSettingsAction: () -> Void {
        get { self[ShowSettingsActionKey.self] }
        set { self[ShowSettingsActionKey.self] = newValue }
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @Environment(VaultManager.self) var vault
    @Environment(TranscriptCache.self) var transcriptCache
    @Environment(DataviewEngine.self) var dataviewEngine
    @State private var showVaultPicker = false
    @State private var showSettings = false
    @State private var selectedTab = 0
    @State private var pendingFile: VaultFile?
    @State private var voiceViewModel = VoicePageViewModel()
    @State private var visibleSyncState: SyncState = .idle
    @State private var syncDebounceTask: Task<Void, Never>?
    @State private var searchPath: [VaultFile] = []
    @State private var browsePath: [VaultFile] = []
    @State private var calendarPath: [VaultFile] = []

    /// Whether the currently selected tab is at its root (no detail pages pushed)
    private var currentTabAtRoot: Bool {
        switch selectedTab {
        case 0: return searchPath.isEmpty
        case 1: return browsePath.isEmpty
        case 4: return calendarPath.isEmpty
        default: return true  // Voice, Create tabs have no navigation stack
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            SearchTab(path: $searchPath, pendingFile: $pendingFile)
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(0)

            BrowseTab(path: $browsePath)
                .tabItem {
                    Label("Browse", systemImage: "folder")
                }
                .tag(1)

            VoicePage(viewModel: voiceViewModel, isTabMode: true) { file in
                pendingFile = file
                selectedTab = 0
            }
            .environment(vault)
            .environment(transcriptCache)
            .environment(dataviewEngine)
            .tabItem {
                Label("Voice", systemImage: "mic.fill")
            }
            .tag(2)

            CreateTab()
                .tabItem {
                    Label("Create", systemImage: "square.and.pencil")
                }
                .tag(3)

            CalendarTab(path: $calendarPath)
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }
                .tag(4)
        }
        .tint(Color.obsidianPurple)
        .environment(\.showSettingsAction, { showSettings = true })
        .overlay(alignment: .leading) {
            // Invisible left-edge strip to capture swipe gesture reliably
            // (NavigationStack and ScrollView eat .gesture on the TabView)
            if !showSettings && currentTabAtRoot {
                Color.clear
                    .frame(width: 24)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                if value.translation.width > 50 {
                                    showSettings = true
                                }
                            }
                    )
            }
        }
        .overlay {
            if showSettings {
                SettingsDrawer(isPresented: $showSettings)
                    .environment(vault)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 4) {
                syncStatusBar

                if let hint = FileAccessLogger.shared.currentHint {
                    AccessHintView(event: hint)
                        .padding(.top, 4)
                }
            }
            .animation(.spring(duration: 0.25), value: FileAccessLogger.shared.currentHint?.id)
            .animation(.easeInOut(duration: 0.3), value: visibleSyncState)
        }
        .onChange(of: vault.syncState) { _, newState in
            syncDebounceTask?.cancel()
            if newState == .idle {
                // Delay hiding so we don't flash on quick transitions
                syncDebounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    visibleSyncState = .idle
                }
            } else if visibleSyncState == .idle {
                // Delay showing so very fast operations don't flash at all
                syncDebounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    visibleSyncState = vault.syncState
                }
            } else {
                // Already showing — update text immediately
                visibleSyncState = newState
            }
        }
        .overlay {
            // Only show blocking overlay if we have no files AND we're not loading from cache
            if vault.files.isEmpty && vault.syncState == .scanning {
                ScanningOverlay(
                    vaultPath: vault.vaultDisplayPath,
                    fullPath: vault.vaultURL?.path ?? "",
                    scanStatus: vault.scanStatus,
                    syncState: vault.syncState,
                    downloadMonitor: vault.downloadMonitor,
                    onChangeVault: { showVaultPicker = true }
                )
            }
        }
        .sheet(isPresented: $showVaultPicker) {
            DocumentPicker { url in
                vault.resetVault()
                vault.saveBookmark(for: url)
            }
        }
    }

    @ViewBuilder
    private var syncStatusBar: some View {
        switch visibleSyncState {
        case .idle:
            EmptyView()
        case .loadingCache:
            SyncBar(text: "Loading...", progress: nil)
        case .scanning:
            if !vault.files.isEmpty {
                let fileCount = vault.files.count
                SyncBar(text: "Scanning... \(fileCount) files", progress: nil)
            }
        case .downloading(let completed, let total):
            let pct = Int(Double(completed) / Double(max(1, total)) * 100)
            SyncBar(text: "\(pct)%", progress: Double(completed) / Double(max(1, total)))
        case .syncing:
            SyncBar(text: "Syncing...", progress: nil)
        }
    }
}

struct SyncBar: View {
    let text: String
    var progress: Double? = nil
    @State private var isDismissed = false

    var body: some View {
        if !isDismissed {
            HStack(spacing: 6) {
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Color.obsidianPurple)
                        .frame(maxWidth: 120)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Button {
                    withAnimation {
                        isDismissed = true
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct ScanningOverlay: View {
    let vaultPath: String
    let fullPath: String
    let scanStatus: String
    let syncState: SyncState
    let downloadMonitor: ICloudDownloadMonitor
    let onChangeVault: () -> Void
    @State private var showFullPath = false

    var body: some View {
        VStack(spacing: 14) {
            if let pct = progressPercent {
                // Show percentage with circular progress
                ZStack {
                    Circle()
                        .stroke(Color.obsidianPurple.opacity(0.2), lineWidth: 4)
                        .frame(width: 56, height: 56)
                    Circle()
                        .trim(from: 0, to: pct)
                        .stroke(Color.obsidianPurple, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 56, height: 56)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: pct)
                    Text("\(Int(pct * 100))%")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .scaleEffect(1.2)
            }

            Text(statusText)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            Divider().frame(width: 200)

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.caption)
                    Text(vaultPath)
                        .font(.caption.bold())
                }
                .foregroundStyle(.secondary)

                if showFullPath {
                    Text(fullPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
            .onTapGesture { showFullPath.toggle() }

            Button("Change Vault", action: onChangeVault)
                .font(.subheadline)
                .foregroundStyle(Color.obsidianPurple)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var progressPercent: Double? {
        if case .downloading(let completed, let total) = syncState {
            return Double(completed) / Double(max(1, total))
        } else if downloadMonitor.isMonitoring {
            return Double(downloadMonitor.downloadedFiles) / Double(max(1, downloadMonitor.totalFiles))
        }
        return nil
    }

    private var statusText: String {
        switch syncState {
        case .scanning:
            return "Scanning vault..."
        case .downloading:
            return "Downloading from iCloud..."
        case .loadingCache:
            return "Loading cached files..."
        case .syncing:
            return "Syncing..."
        case .idle:
            return "Loading..."
        }
    }
}
