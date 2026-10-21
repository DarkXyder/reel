import SwiftUI

@main
struct ReelApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var addons = AddonStore()
    @StateObject private var library = LibraryStore()
    @StateObject private var debrid = DebridService()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var trakt = TraktService.shared

    init() {
        // Posters are loaded with AsyncImage, which uses the shared URL cache.
        URLCache.shared = URLCache(memoryCapacity: 50 << 20, diskCapacity: 300 << 20)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(addons)
                .environmentObject(library)
                .environmentObject(debrid)
                .environmentObject(settings)
                .environmentObject(downloads)
                .environmentObject(trakt)
                .preferredColorScheme(.dark)
                .tint(Color.accentColor)
                .task {
                    // Bring in progress from other devices.
                    if trakt.isConnected { await trakt.importProgress(into: library, addons: addons) }
                }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}
