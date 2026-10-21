import SwiftUI

/// Movie / series page: artwork, description, library button, seasons and episodes.
struct DetailView: View {
    let preview: MetaPreview
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.openURL) private var openURL
    @State private var meta: MetaDetail?
    @State private var similar: [MetaPreview] = []
    @State private var toast: String?
    @State private var error: String?
    @State private var season: Int = 1
    @State private var streamsFor: StreamTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions.padding(.horizontal)
                if !isSeries, let p = library.progress(metaId: preview.id, videoId: preview.id), p.fraction > 0.01 {
                    HStack(spacing: 10) {
                        ProgressView(value: p.fraction).tint(Color.reel)
                        Text(p.isWatched ? "Watched" : "\(remaining(p)) left")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
                if let d = meta?.description ?? preview.description {
                    Text(d).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
                }
                if let genres = meta?.genres, !genres.isEmpty {
                    Text(genres.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                credits
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
                }
                if isSeries { episodes }
                if !similar.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "More like this")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(similar) { m in
                                    NavigationLink(value: m) { PosterCard(meta: m) }.buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
        .navigationDestination(for: SearchQuery.self) { SearchResultsView(query: $0.text) }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $streamsFor) { target in
            StreamsView(target: target)
                .presentationDetents([.medium, .large])
        }
    }

    private var isSeries: Bool {
        (meta?.type ?? preview.type) != "movie" && !(meta?.videos ?? []).isEmpty
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            PosterImage(url: meta?.background ?? preview.background ?? meta?.poster ?? preview.poster, landscape: true)
                .frame(maxWidth: .infinity)
                .clipShape(Rectangle())
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom))
                // Darken the top so the back button stays readable on bright artwork.
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 130)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(meta?.name ?? preview.name).font(.largeTitle.weight(.bold)).lineLimit(2)
                HStack(spacing: 10) {
                    if let r = (meta?.releaseInfo ?? preview.releaseInfo)?.value, !r.isEmpty { Text(r) }
                    if let rt = meta?.runtime { Text(rt) }
                    if let imdb = (meta?.imdbRating ?? preview.imdbRating)?.value, !imdb.isEmpty {
                        Label(imdb, systemImage: "star.fill")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if !isSeries {
                Button {
                    streamsFor = StreamTarget(meta: currentPreview, type: currentPreview.type, videoId: currentPreview.id, videoTitle: nil)
                } label: {
                    Label(resumeLabel(videoId: currentPreview.id), systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if let e = library.entries[preview.id], e.isInProgress, let vid = e.lastVideoId {
                Button {
                    streamsFor = StreamTarget(meta: currentPreview, type: currentPreview.type, videoId: vid, videoTitle: e.lastVideoTitle,
                                              episodes: orderedEpisodes)
                } label: {
                    Label("Resume \(e.lastVideoTitle ?? "")", systemImage: "play.fill").lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Button { library.toggleLibrary(currentPreview) } label: {
                Image(systemName: library.isInLibrary(preview.id) ? "checkmark" : "plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            if let yt = meta?.trailerYouTubeId, let url = URL(string: "https://www.youtube.com/watch?v=\(yt)") {
                Button { openURL(url) } label: {
                    Image(systemName: "play.rectangle").frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel("Trailer")
            }
            if !isSeries {
                downloadButton(videoId: currentPreview.id, title: nil).buttonStyle(.bordered).controlSize(.large)
            }
        }
    }

    /// Download state for one video: download, progress, or done.
    @ViewBuilder
    private func downloadButton(videoId: String, title: String?) -> some View {
        if downloads.record(forVideo: videoId) != nil {
            Button {} label: { Image(systemName: "arrow.down.circle.fill").frame(width: 24, height: 24) }
                .disabled(true)
        } else if let d = downloads.isDownloading(videoId) {
            Button {} label: {
                ProgressView(value: d.fraction).progressViewStyle(.circular).frame(width: 24, height: 24)
            }
            .disabled(true)
        } else {
            Button { Task { await download(videoId: videoId, title: title) } } label: {
                Image(systemName: "arrow.down.circle").frame(width: 24, height: 24)
            }
            .accessibilityLabel("Download")
        }
    }

    private func download(videoId: String, title: String?) async {
        show("Finding a stream to download…")
        let ok = await downloads.downloadBest(meta: currentPreview, type: currentPreview.type, videoId: videoId,
                                              videoTitle: title, addons: addons)
        show(ok ? "Downloading: Library → Downloads" : "No downloadable stream found")
    }

    private func downloadSeason() async {
        let list = orderedEpisodes.filter { ($0.season ?? 1) == season && !$0.isUnreleased }
        show("Queuing \(list.count) episodes…")
        var queued = 0
        for v in list {
            if await downloads.downloadBest(meta: currentPreview, type: currentPreview.type, videoId: v.id,
                                            videoTitle: NextEpisode.title(v), addons: addons) {
                queued += 1
            }
        }
        show("\(queued) of \(list.count) episodes downloading")
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        let shown = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == shown { withAnimation { toast = nil } }
        }
    }

    /// Director and cast; tapping a name searches for it.
    @ViewBuilder
    private var credits: some View {
        let cast = meta?.cast?.values ?? []
        let directors = meta?.director?.values ?? []
        if !directors.isEmpty {
            Text("Director: " + directors.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
        }
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cast").font(.headline).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(cast.prefix(15), id: \.self) { name in
                            NavigationLink(value: SearchQuery(text: name)) {
                                HStack(spacing: 6) {
                                    Text(initials(name)).font(.caption2.weight(.bold))
                                        .frame(width: 26, height: 26)
                                        .background(Color.reel.opacity(0.25), in: Circle())
                                    Text(name).font(.caption)
                                }
                                .padding(.vertical, 5).padding(.leading, 5).padding(.trailing, 12)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    private var currentPreview: MetaPreview { meta?.preview ?? preview }

    private var orderedEpisodes: [Video] { Video.ordered(meta?.videos ?? []) }

    private func resumeLabel(videoId: String) -> String {
        library.resumePosition(metaId: preview.id, videoId: videoId) != nil ? "Resume" : "Watch"
    }

    private var seasons: [Int] {
        let all = Set((meta?.videos ?? []).compactMap(\.season))
        // Season 0 (specials) last.
        return all.sorted { a, b in a == 0 ? false : (b == 0 ? true : a < b) }
    }

    private var episodes: some View {
        VStack(alignment: .leading, spacing: 12) {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(seasons, id: \.self) { s in
                            Button(s == 0 ? "Specials" : "Season \(s)") { season = s }
                                .buttonStyle(.bordered)
                                .tint(s == season ? Color.reel : Color.gray)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            HStack {
                Spacer()
                Button { Task { await downloadSeason() } } label: {
                    Label(season == 0 ? "Download specials" : "Download season \(season)", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
            }
            ForEach((meta?.videos ?? []).filter { ($0.season ?? 1) == season }.sorted { $0.episodeNumber < $1.episodeNumber }) { v in
                Button {
                    streamsFor = StreamTarget(meta: currentPreview, type: currentPreview.type, videoId: v.id,
                                              videoTitle: NextEpisode.title(v), episodes: orderedEpisodes)
                } label: {
                    EpisodeRow(video: v, progress: library.progress(metaId: preview.id, videoId: v.id),
                               downloaded: downloads.record(forVideo: v.id) != nil,
                               downloading: downloads.isDownloading(v.id)?.fraction)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .contextMenu {
                    if downloads.record(forVideo: v.id) == nil && downloads.isDownloading(v.id) == nil {
                        Button { Task { await download(videoId: v.id, title: NextEpisode.title(v)) } } label: {
                            Label("Download episode", systemImage: "arrow.down.circle")
                        }
                    }
                }
            }
        }
    }

    /// Same genre, from a catalog that can filter by genre (Cinemeta's Popular).
    private func loadSimilar(_ m: MetaDetail) async {
        guard let genre = m.genres?.first else { return }
        let sources = addons.addons.flatMap { a in
            (a.manifest.catalogs ?? []).filter { $0.type == m.type && $0.genres.contains(genre) }.map { CatalogRef(addon: a, catalog: $0) }
        }
        guard let src = sources.first else { return }
        let items = (try? await AddonClient.shared.catalog(src.addon, src.catalog, genre: genre)) ?? []
        similar = Array(items.filter { $0.id != m.id }.prefix(15))
    }

    private func load() async {
        guard meta == nil else { return }
        let providers = addons.supporting("meta", type: preview.type, id: preview.id)
        for addon in providers {
            if let m = try? await AddonClient.shared.meta(addon, type: preview.type, id: preview.id) {
                meta = m
                Task { await loadSimilar(m) }
                let firstSeason = seasons.first(where: { $0 > 0 }) ?? seasons.first ?? 1
                if let e = library.entries[preview.id], let vid = e.lastVideoId,
                   let v = m.videos?.first(where: { $0.id == vid }), let s = v.season {
                    season = s
                } else {
                    season = firstSeason
                }
                return
            }
        }
        if providers.isEmpty { error = "No add-on provides details for this title." }
    }
}

struct EpisodeRow: View {
    let video: Video
    let progress: VideoProgress?
    var downloaded = false
    var downloading: Double? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterImage(url: video.thumbnail, landscape: true).frame(width: 140)
                .overlay(ProgressOverlay(progress: progress))
                .overlay(alignment: .topLeading) {
                    if downloaded {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 16))
                            .symbolRenderingMode(.palette).foregroundStyle(.white, Color.reel).padding(6)
                    } else if let f = downloading {
                        ProgressView(value: f).progressViewStyle(.circular).tint(.white).scaleEffect(0.6)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(video.episodeNumber). \(video.displayTitle)").font(.subheadline.weight(.semibold)).lineLimit(2)
                if let p = progress, p.isResumable {
                    Text("\(remaining(p)) left").font(.caption2.weight(.semibold)).foregroundStyle(Color.reel)
                }
                if let s = video.summary {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

func remaining(_ p: VideoProgress) -> String {
    let m = max(1, Int((p.duration - p.position) / 60))
    return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
}

/// What to find streams for.
struct StreamTarget: Identifiable {
    let meta: MetaPreview
    let type: String
    let videoId: String
    let videoTitle: String?
    /// All episodes in order, so the player can go on to the next one.
    var episodes: [Video] = []
    var id: String { videoId }
}
