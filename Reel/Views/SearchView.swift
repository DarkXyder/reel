import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var addons: AddonStore
    @State private var query = ""
    @State private var results: [SearchSection] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    struct SearchSection: Identifiable {
        let id: String
        let title: String
        let items: [MetaPreview]
    }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ScrollView {
            if addons.searchCatalogs.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "Search unavailable",
                           message: "None of your add-ons supports search. Cinemeta (installed by default) does.")
            } else if query.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "Search movies and series", message: "Results come from your add-ons.")
            } else if results.isEmpty && !searching {
                EmptyState(icon: "questionmark", title: "No results", message: "Try another title.")
            }
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(results) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: section.title)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(section.items) { m in
                                NavigationLink(value: m) { PosterCard(meta: m, width: 104) }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .overlay { if searching && results.isEmpty { ProgressView() } }
        .navigationTitle("Search")
        .navigationDestination(for: MetaPreview.self) { DetailView(preview: $0) }
        .searchable(text: $query, prompt: "Movies, series…")
        .onChange(of: query) { q in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000) // wait until typing pauses
                if !Task.isCancelled { await run(q) }
            }
        }
    }

    @MainActor
    private func run(_ q: String) async {
        let text = q.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { results = []; return }
        searching = true
        defer { searching = false }
        var found: [SearchSection] = []
        let sources = addons.searchCatalogs
        await withTaskGroup(of: SearchSection?.self) { group in
            for src in sources {
                group.addTask {
                    guard let items = try? await AddonClient.shared.catalog(src.addon, src.catalog, search: text),
                          !items.isEmpty else { return nil }
                    return SearchSection(id: src.id,
                                         title: "\(src.catalog.type.capitalized) · \(src.addon.manifest.name)",
                                         items: items)
                }
            }
            for await s in group { if let s { found.append(s) } }
        }
        guard text == query.trimmingCharacters(in: .whitespaces) else { return }
        let order = sources.map(\.id)
        results = found.sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
    }
}
