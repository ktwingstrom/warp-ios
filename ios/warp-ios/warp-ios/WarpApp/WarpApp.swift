import SwiftUI

@main
struct WarpApp: App {
    init() {
        // Spin up the Tokio runtime on a background thread so app launch isn't
        // blocked waiting for the thread pool to start.  The first SSH connect
        // will block at most until this finishes, which is usually done well
        // before the user reaches the connect screen.
        Task.detached(priority: .userInitiated) {
            initializeBridge()
        }
    }

    var body: some Scene {
        WindowGroup {
            HostListView()
                .preferredColorScheme(.dark)
        }
    }
}
