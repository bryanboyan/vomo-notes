import SwiftUI

@main
struct VomoWatchApp: App {
    @State private var connectivity = WatchConnectivityManager.shared

    var body: some Scene {
        WindowGroup {
            WatchMainView()
                .environment(connectivity)
        }
    }
}
