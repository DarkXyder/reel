import SwiftUI

@main
struct ReelApp: App {
    @StateObject private var addons = AddonStore()
    @StateObject private var library = LibraryStore()
    @StateObject private var debrid = DebridService()

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
                .preferredColorScheme(.dark)
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
