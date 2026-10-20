import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if !library.continueWatching.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Continue watching")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(library.continueWatching) { e in
                                    NavigationLink(value: e.preview) { ContinueCard(entry: e) }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button(role: .destructive) { library.clearProgress(e.id) } label: {
                                                Label("Remove from Continue watching", systemImage: "xmark")
                                            }
                                        }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                ForEach(addons.homeCatalogs) { row in
                    CatalogRow(addon: row.addon, catalog: row.catalog)
                }
                if addons.addons.isEmpty {
                    EmptyState(icon: "puzzlepiece.extension", title: "No add-ons",
                               message: "Add Stremio add-ons in Settings to see catalogs here.")
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Reel")
        .navigationDestination(for: MetaPreview.self) { DetailView(preview: $0) }
        .refreshable { await addons.refreshAll() }
    }
}

/// One horizontal row of posters from an add-on catalog. Loads when it scrolls into view.
struct CatalogRow: View {
    let addon: InstalledAddon
    let catalog: CatalogDef
    @State private var items: [MetaPreview] = []
    @State private var failed = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "\(catalog.name ?? catalog.id) · \(catalog.type.capitalized)",
                          subtitle: addon.manifest.name)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    if !loaded {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)).frame(width: 112, height: 168)
                        }
                    }
                    ForEach(items) { m in
                        NavigationLink(value: m) { PosterCard(meta: m) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            if failed {
                Text("Couldn't load this catalog.").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
        }
        .task {
            guard !loaded else { return }
            do {
                items = try await AddonClient.shared.catalog(addon, catalog)
            } catch {
                failed = true
            }
            loaded = true
        }
    }
}
