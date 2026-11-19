import SwiftUI
import UIKit

@main
struct VideoIntelligenceNativeApp: App {
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .task { await library.load() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task { await library.releaseTranscriptionEngine() }
                }
        }
    }
}
