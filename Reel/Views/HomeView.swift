import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var upNext: UpNextService
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var streamsFor: StreamTarget?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if let featured = addons.homeCatalogs.first {
                    FeaturedBanner(source: featured)
                }
                if !library.continueWatching.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Continue watching")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(library.continueWatching) { e in
                                    NavigationLink(value: e.preview) { ContinueCard(entry: e, width: sizeClass == .regular ? 300 : 220) }
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
                if !upNext.items.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Up next")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(upNext.items) { item in
                                    Button {
                                        streamsFor = StreamTarget(meta: item.entry.preview, type: item.entry.type, videoId: item.video.id,
                                                                  videoTitle: NextEpisode.title(item.video), episodes: item.episodes)
                                    } label: {
                                        UpNextCard(item: item, width: sizeClass == .regular ? 300 : 220)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        NavigationLink(value: item.entry.preview) { Label("Show details", systemImage: "info.circle") }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                ForEach(addons.homeCatalogs) { row in
                    CatalogRow(source: row)
                }
                if addons.addons.isEmpty {
                    EmptyState(icon: "puzzlepiece.extension", title: "No add-ons",
                               message: "Add Stremio add-ons in Settings to see catalogs here.")
                }
            }
            .padding(.bottom)
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle("Reel")
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: MetaPreview.self) { DetailView(preview: $0) }
        .navigationDestination(for: CatalogRef.self) { CatalogGridView(source: $0) }
        .refreshable {
            await addons.refreshAll()
            await upNext.refresh(library: library, addons: addons)
        }
        .onAppear { Task { await upNext.refresh(library: library, addons: addons) } }
        .sheet(item: $streamsFor) { target in
            StreamsView(target: target).presentationDetents([.medium, .large])
        }
    }
}

/// Next episode card: its thumbnail, the show, and "S2E4 · Title".
struct UpNextCard: View {
    let item: UpNextItem
    var width: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: item.video.thumbnail ?? item.entry.background ?? item.entry.poster, landscape: true)
                .frame(width: width)
                .overlay(alignment: .bottomLeading) {
                    Label("Next", systemImage: "play.fill").font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.reel, in: Capsule()).foregroundStyle(.white).padding(8)
                }
            Text(item.entry.name).font(.caption.weight(.semibold)).lineLimit(1)
            Text(NextEpisode.title(item.video)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Big swipeable artwork carousel from the first catalog, advancing every few seconds.
struct FeaturedBanner: View {
    let source: CatalogRef
    @State private var items: [MetaPreview] = []
    @State private var page = 0
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let timer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, m in
                NavigationLink(value: m) { slide(m) }.buttonStyle(.plain).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .frame(height: sizeClass == .regular ? 460 : 300)
        .background(Color.primary.opacity(0.04))
        .task {
            guard items.isEmpty else { return }
            let all = (try? await AddonClient.shared.catalog(source.addon, source.catalog)) ?? []
            items = Array(all.filter { $0.background != nil }.prefix(8))
        }
        .onReceive(timer) { _ in
            guard items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.6)) { page = (page + 1) % items.count }
        }
    }

    private func slide(_ m: MetaPreview) -> some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { g in
                AsyncImage(url: m.background.flatMap(URL.init(string:))) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.clear }
                .frame(width: g.size.width, height: g.size.height)
                .clipped()
            }
            LinearGradient(colors: [.black.opacity(0.5), .clear, .clear, .black.opacity(0.95)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                if let logo = m.logo.flatMap(URL.init(string:)) {
                    AsyncImage(url: logo) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                        Text(m.name).font(.largeTitle.weight(.heavy))
                    }
                    .frame(maxWidth: 260, maxHeight: 80, alignment: .leading)
                } else {
                    Text(m.name).font(.largeTitle.weight(.heavy)).lineLimit(2)
                }
                HStack(spacing: 10) {
                    if let r = m.releaseInfo?.value, !r.isEmpty { Text(r) }
                    if let imdb = m.imdbRating?.value, !imdb.isEmpty { Label(imdb, systemImage: "star.fill") }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 36)
        }
        .foregroundStyle(.white)
    }
}

/// One horizontal row of posters from an add-on catalog. Loads when it scrolls into view.
struct CatalogRow: View {
    let source: CatalogRef
    @State private var items: [MetaPreview] = []
    @State private var failed = false
    @State private var loaded = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var width: CGFloat { sizeClass == .regular ? 150 : 112 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(source.catalog.name ?? source.catalog.id) · \(source.catalog.type.capitalized)")
                    .font(.title3.weight(.semibold))
                Text(source.addon.manifest.name).font(.caption).foregroundStyle(.secondary)
                Spacer()
                NavigationLink(value: source) {
                    HStack(spacing: 2) { Text("See all"); Image(systemName: "chevron.right") }.font(.subheadline)
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    if !loaded {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)).frame(width: width, height: width * 1.5)
                        }
                    }
                    ForEach(items) { m in
                        NavigationLink(value: m) { PosterCard(meta: m, width: width) }.buttonStyle(.plain)
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
                items = try await AddonClient.shared.catalog(source.addon, source.catalog)
            } catch {
                failed = true
            }
            loaded = true
        }
    }
}

/// A whole catalog as a grid: genre filter, loads more as you scroll.
struct CatalogGridView: View {
    let source: CatalogRef
    @State private var items: [MetaPreview] = []
    @State private var genre: String?
    @State private var loading = false
    @State private var reachedEnd = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: sizeClass == .regular ? 140 : 104), spacing: 12)] }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(items) { m in
                    NavigationLink(value: m) { PosterCard(meta: m, width: sizeClass == .regular ? 140 : 104) }
                        .buttonStyle(.plain)
                        .onAppear { if m.id == items.last?.id { Task { await loadMore() } } }
                }
            }
            .padding()
            if loading { ProgressView().padding() }
            if !loading && items.isEmpty { EmptyState(icon: "film", title: "Nothing here", message: "Try another genre.") }
        }
        .navigationTitle(source.catalog.name ?? source.catalog.id)
        .toolbar {
            if !source.catalog.genres.isEmpty {
                Menu {
                    Picker("Genre", selection: $genre) {
                        Text("All genres").tag(String?.none)
                        ForEach(source.catalog.genres, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                } label: {
                    Label(genre ?? "Genre", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .task { if items.isEmpty { await loadMore() } }
        .onChange(of: genre) { _ in
            items = []
            reachedEnd = false
            Task { await loadMore() }
        }
    }

    private func loadMore() async {
        guard !loading, !reachedEnd else { return }
        loading = true
        defer { loading = false }
        let wanted = genre
        let page = (try? await AddonClient.shared.catalog(source.addon, source.catalog, genre: wanted, skip: items.count)) ?? []
        guard wanted == genre else { return }
        let known = Set(items.map(\.id))
        let fresh = page.filter { !known.contains($0.id) }
        if fresh.isEmpty { reachedEnd = true }
        items += fresh
    }
}
