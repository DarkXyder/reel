import SwiftUI

/// Movie / series page: artwork, description, library button, seasons and episodes.
struct DetailView: View {
    let preview: MetaPreview
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryStore
    @State private var meta: MetaDetail?
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
                        ProgressView(value: p.fraction).tint(Color.accentColor)
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
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
                }
                if isSeries { episodes }
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
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
        }
    }

    private var currentPreview: MetaPreview { meta?.preview ?? preview }

    /// Season 1… in order, specials (season 0) last.
    private var orderedEpisodes: [Video] {
        (meta?.videos ?? []).sorted { a, b in
            let sa = a.season ?? 1, sb = b.season ?? 1
            if sa != sb { return sa == 0 ? false : (sb == 0 ? true : sa < sb) }
            return a.episodeNumber < b.episodeNumber
        }
    }

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
                                .tint(s == season ? Color.accentColor : Color.gray)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            ForEach((meta?.videos ?? []).filter { ($0.season ?? 1) == season }.sorted { $0.episodeNumber < $1.episodeNumber }) { v in
                Button {
                    streamsFor = StreamTarget(meta: currentPreview, type: currentPreview.type, videoId: v.id,
                                              videoTitle: NextEpisode.title(v), episodes: orderedEpisodes)
                } label: {
                    EpisodeRow(video: v, progress: library.progress(metaId: preview.id, videoId: v.id))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
        }
    }

    private func load() async {
        guard meta == nil else { return }
        let providers = addons.supporting("meta", type: preview.type, id: preview.id)
        for addon in providers {
            if let m = try? await AddonClient.shared.meta(addon, type: preview.type, id: preview.id) {
                meta = m
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterImage(url: video.thumbnail, landscape: true).frame(width: 140)
                .overlay(ProgressOverlay(progress: progress))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(video.episodeNumber). \(video.displayTitle)").font(.subheadline.weight(.semibold)).lineLimit(2)
                if let p = progress, p.isResumable {
                    Text("\(remaining(p)) left").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
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
