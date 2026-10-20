import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var debrid: DebridService
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if debrid.hasKey {
                    NavigationLink { DebridFilesView() } label: {
                        HStack {
                            Image(systemName: "externaldrive.connected.to.line.below")
                            Text("My \(debrid.provider.rawValue) files")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
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
                            NavigationLink(value: e.preview) { PosterCard(meta: e.preview, width: 104) }
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
            PlayerScreen(request: req, library: library).environmentObject(addons)
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
            playing = PlayRequest(url: url, meta: meta, type: "other", videoId: meta.id, videoTitle: nil,
                                  streamSubtitles: [], headers: [:],
                                  resumeAt: library.resumePosition(metaId: meta.id, videoId: meta.id))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
