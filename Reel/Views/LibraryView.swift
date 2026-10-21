import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var debrid: DebridService
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: sizeClass == .regular ? 140 : 104), spacing: 12)] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !downloads.records.isEmpty {
                    NavigationLink { DownloadsView() } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                            Text("Downloads")
                            Spacer()
                            let active = downloads.records.filter { $0.state == .downloading }.count
                            if active > 0 { Text("\(active) in progress").font(.caption).foregroundStyle(.secondary) }
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                }
                if debrid.hasKey {
                    NavigationLink { DebridFilesView() } label: {
                        HStack {
                            Image(systemName: "externaldrive.connected.to.line.below")
                            Text("My \(debrid.provider.rawValue) files")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                }
                if library.library.isEmpty {
                    EmptyState(icon: "books.vertical", title: "Your library is empty",
                               message: "Tap + on a movie or series to save it here.")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(library.library) { e in
                            NavigationLink(value: e.preview) { PosterCard(meta: e.preview, width: sizeClass == .regular ? 140 : 104) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) { library.toggleLibrary(e.preview) } label: {
                                        Label("Remove from library", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Library")
        .navigationDestination(for: MetaPreview.self) { DetailView(preview: $0) }
    }
}

/// Files in your own debrid account, playable directly.
struct DebridFilesView: View {
    @EnvironmentObject private var debrid: DebridService
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloads: DownloadManager
    @State private var files: [DebridFile] = []
    @State private var error: String?
    @State private var loading = true
    @State private var playing: PlayRequest?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(files) { f in
                Button { Task { await play(f) } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.filename).font(.subheadline).lineLimit(2)
                        HStack {
                            if let s = f.size { Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
                            if let d = f.date { Text(d, style: .date) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button { Task { await download(f) } } label: { Label("Download", systemImage: "arrow.down.circle") }
                }
            }
        }
        .overlay {
            if loading { ProgressView() }
            else if files.isEmpty && error == nil {
                EmptyState(icon: "tray", title: "Nothing here", message: "Files you add to your \(debrid.provider.rawValue) account appear here.")
            }
        }
        .navigationTitle("My files")
        .refreshable { await load() }
        .task { await load() }
        .fullScreenCover(item: $playing) { req in
            PlayerHost(request: req)
                .environmentObject(addons).environmentObject(library)
                .environmentObject(settings).environmentObject(downloads)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            files = try await debrid.files()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func play(_ f: DebridFile) async {
        do {
            let url = try await debrid.playableURL(f)
            let meta = MetaPreview(id: "debrid:\(f.id)", type: "other", name: f.filename, poster: nil, posterShape: nil,
                                   background: nil, logo: nil, description: nil, releaseInfo: nil, imdbRating: nil)
            var req = PlayRequest(url: url, meta: meta, type: "other", videoId: meta.id, videoTitle: nil,
                                  streamSubtitles: [], headers: [:],
                                  resumeAt: library.resumePosition(metaId: meta.id, videoId: meta.id))
            req.fileExtension = (f.filename as NSString).pathExtension.lowercased()
            playing = req
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func download(_ f: DebridFile) async {
        do {
            let url = try await debrid.playableURL(f)
            let meta = MetaPreview(id: "debrid:\(f.id)", type: "other", name: f.filename, poster: nil, posterShape: nil,
                                   background: nil, logo: nil, description: nil, releaseInfo: nil, imdbRating: nil)
            downloads.start(url: url, meta: meta, type: "other", videoId: meta.id, videoTitle: nil,
                            fileExtension: (f.filename as NSString).pathExtension)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Downloaded and downloading videos.
struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var settings: AppSettings
    @State private var playing: PlayRequest?

    var body: some View {
        List {
            ForEach(downloads.records) { r in
                Button { play(r) } label: {
                    HStack(spacing: 12) {
                        PosterImage(url: r.meta.poster).frame(width: 46)
                            .overlay(ProgressOverlay(progress: library.progress(metaId: r.meta.id, videoId: r.videoId)))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                            switch r.state {
                            case .downloading:
                                ProgressView(value: r.fraction).tint(Color.reel)
                                Text(r.total > 0
                                     ? "\(ByteCountFormatter.string(fromByteCount: r.received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: r.total, countStyle: .file))"
                                     : "Starting…")
                                    .font(.caption2).foregroundStyle(.secondary)
                            case .done:
                                Text(ByteCountFormatter.string(fromByteCount: max(r.received, r.total), countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            case .failed:
                                Text("Failed: \(r.error ?? "unknown error")").font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                .disabled(r.state != .done)
                .swipeActions {
                    Button(role: .destructive) { downloads.delete(r) } label: { Label("Delete", systemImage: "trash") }
                    if r.state == .failed {
                        Button { downloads.retry(r) } label: { Label("Retry", systemImage: "arrow.clockwise") }.tint(.orange)
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .overlay {
            if downloads.records.isEmpty {
                EmptyState(icon: "arrow.down.circle", title: "No downloads",
                           message: "Long-press a stream and choose Download.")
            }
        }
        .fullScreenCover(item: $playing) { req in
            PlayerHost(request: req)
                .environmentObject(addons).environmentObject(library)
                .environmentObject(settings).environmentObject(downloads)
        }
    }

    private func play(_ r: DownloadRecord) {
        var req = PlayRequest(url: downloads.localURL(r), meta: r.meta, type: r.type, videoId: r.videoId,
                              videoTitle: r.videoTitle, streamSubtitles: [], headers: [:],
                              resumeAt: library.resumePosition(metaId: r.meta.id, videoId: r.videoId))
        req.fileExtension = r.fileExtension
        playing = req
    }
}
