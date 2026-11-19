import SwiftUI

@main
struct VideoIntelligenceNativeApp: App {
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .task { await library.load() }
        }
    }
}
