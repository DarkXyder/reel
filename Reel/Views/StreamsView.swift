import SwiftUI
import UIKit

/// Streams for one movie or episode, from every installed add-on that offers streams.
/// Filter by quality, sort, pin a favourite add-on, play, download or open elsewhere.
struct StreamsView: View {
    let target: StreamTarget
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.openURL) private var openURL
    @State private var found: [Found] = []
    @State private var pending = 0
    @State private var torrentOnly = 0
    @State private var quality: StreamQuality?
    @State private var playing: PlayRequest?
    @State private var toast: String?

    struct Found: Identifiable {
        let id = UUID()
        let addon: InstalledAddon
        let stream: StreamItem
        let order: Int
    }

    var body: some View {
        NavigationStack {
            List {
                if let local = downloads.record(forVideo: target.videoId) {
                    Section("Downloaded") {
                        Button { playDownload(local) } label: {
                            Label("Play offline copy", systemImage: "arrow.down.circle.fill")
                        }
                    }
                }
                if !found.isEmpty { filterBar.listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                if visible.isEmpty && pending == 0 {
                    EmptyState(icon: "play.slash", title: found.isEmpty ? "No streams" : "Nothing in \(quality?.label ?? "")",
                               message: emptyMessage)
                        .listRowBackground(Color.clear)
                }
                if settings.streamSort == .addon {
                    ForEach(groupedVisible) { g in
                        Section(g.name) { ForEach(g.items) { row($0, showAddon: false) } }
                    }
                } else {
                    Section { ForEach(visible) { row($0, showAddon: true) } }
                }
                if torrentOnly > 0 {
                    Section {
                        Text("\(torrentOnly) torrent result(s) hidden: Reel plays direct links only.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { if pending > 0 && found.isEmpty { ProgressView("Finding streams…") } }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle(target.videoTitle ?? target.meta.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Menu {
                    Picker("Sort", selection: $settings.streamSort) {
                        ForEach(StreamSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .task { await load() }
        .fullScreenCover(item: $playing) { req in
            PlayerHost(request: req)
                .environmentObject(addons).environmentObject(library)
                .environmentObject(settings).environmentObject(downloads)
        }
    }

    // MARK: - filtering & sorting

    private var emptyMessage: String {
        if !found.isEmpty { return "Try another quality." }
        return addons.supporting("stream", type: target.type, id: target.videoId).isEmpty
            ? "None of your add-ons provides streams for this. Add one in Settings → Add-ons."
            : "Your add-ons found nothing playable for this title."
    }

    private var availableQualities: [StreamQuality] {
        Set(found.map(\.stream.quality)).sorted(by: >)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All (\(found.count))", selected: quality == nil) { quality = nil }
                ForEach(availableQualities) { q in
                    chip("\(q.label) (\(found.filter { $0.stream.quality == q }.count))", selected: quality == q) { quality = q }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Color.accentColor : Color.white.opacity(0.1), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    /// Filtered, with the preferred add-on first, in the chosen order.
    private var visible: [Found] {
        let list = found.filter { quality == nil || $0.stream.quality == quality }
        let pref = settings.preferredAddon
        return list.sorted { a, b in
            let pa = a.addon.id == pref, pb = b.addon.id == pref
            if pa != pb { return pa }
            switch settings.streamSort {
            case .addon: return a.order < b.order
            case .quality:
                if a.stream.quality != b.stream.quality { return a.stream.quality > b.stream.quality }
                return (a.stream.sizeBytes ?? 0) > (b.stream.sizeBytes ?? 0)
            case .largest: return (a.stream.sizeBytes ?? 0) > (b.stream.sizeBytes ?? 0)
            case .smallest: return (a.stream.sizeBytes ?? .max) < (b.stream.sizeBytes ?? .max)
            }
        }
    }

    struct StreamGroup: Identifiable {
        let name: String
        var items: [Found]
        var id: String { name }
    }

    private var groupedVisible: [StreamGroup] {
        var groups: [StreamGroup] = []
        for f in visible {
            let name = f.addon.manifest.name + (f.addon.id == settings.preferredAddon ? " ★" : "")
            if let i = groups.firstIndex(where: { $0.name == name }) { groups[i].items.append(f) }
            else { groups.append(StreamGroup(name: name, items: [f])) }
        }
        return groups
    }

    // MARK: - rows

    private func row(_ f: Found, showAddon: Bool) -> some View {
        let s = f.stream
        return Button { play(f) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if s.quality != .unknown {
                        Text(s.quality.label).font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(s.quality >= .hd1080 ? Color.accentColor : Color.gray.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                    }
                    if let size = s.sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                    }
                    if showAddon { Text(f.addon.manifest.name).font(.caption2).foregroundStyle(.secondary) }
                }
                Text(s.heading).font(.subheadline.weight(.semibold))
                if !s.details.isEmpty {
                    Text(s.details).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
                if s.externalUrl != nil || s.ytId != nil {
                    Label("Opens outside Reel", systemImage: "arrow.up.forward.app").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            if let url = s.url.flatMap(URL.init(string:)) {
                Button { play(f, force: .apple) } label: { Label("Play with Apple player (AirPlay, PiP)", systemImage: "airplayvideo") }
                Button { play(f, force: .vlc) } label: { Label("Play with VLC", systemImage: "play.rectangle") }
                Button {
                    downloads.start(url: url, meta: target.meta, type: target.type, videoId: target.videoId,
                                    videoTitle: target.videoTitle, fileExtension: s.fileExtension)
                    show("Download started: see Library → Downloads")
                } label: { Label("Download", systemImage: "arrow.down.circle") }
                Button { openExternal("vlc-x-callback://x-callback-url/stream?url=", url) } label: { Label("Open in VLC app", systemImage: "arrow.up.forward.app") }
                Button { openExternal("infuse://x-callback-url/play?url=", url) } label: { Label("Open in Infuse", systemImage: "arrow.up.forward.app") }
                Button { UIPasteboard.general.string = url.absoluteString; show("Link copied") } label: { Label("Copy link", systemImage: "doc.on.doc") }
            }
            Divider()
            if settings.preferredAddon == f.addon.id {
                Button { settings.preferredAddon = nil } label: { Label("Stop listing \(f.addon.manifest.name) first", systemImage: "star.slash") }
            } else {
                Button { settings.preferredAddon = f.addon.id } label: { Label("Always list \(f.addon.manifest.name) first", systemImage: "star") }
            }
        }
    }

    // MARK: - actions

    private func play(_ f: Found, force: PlayerMode? = nil) {
        let s = f.stream
        if let u = s.url, let url = URL(string: u) {
            var req = PlayRequest(url: url, meta: target.meta, type: target.type, videoId: target.videoId,
                                  videoTitle: target.videoTitle, streamSubtitles: s.subtitles ?? [],
                                  headers: s.behaviorHints?.proxyHeaders?.request ?? [:],
                                  resumeAt: library.resumePosition(metaId: target.meta.id, videoId: target.videoId))
            req.addonId = f.addon.id
            req.bingeGroup = s.behaviorHints?.bingeGroup
            req.fileExtension = s.fileExtension
            req.episodes = target.episodes
            req.forcePlayer = force
            playing = req
        } else if let e = s.externalUrl, let url = URL(string: e) {
            openURL(url)
        } else if let yt = s.ytId, let url = URL(string: "https://www.youtube.com/watch?v=\(yt)") {
            openURL(url)
        }
    }

    private func playDownload(_ r: DownloadRecord) {
        var req = PlayRequest(url: downloads.localURL(r), meta: target.meta, type: target.type, videoId: target.videoId,
                              videoTitle: target.videoTitle, streamSubtitles: [], headers: [:],
                              resumeAt: library.resumePosition(metaId: target.meta.id, videoId: target.videoId))
        req.fileExtension = r.fileExtension
        req.episodes = target.episodes
        playing = req
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }

    private func openExternal(_ prefix: String, _ url: URL) {
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        if let u = URL(string: prefix + encoded) { openURL(u) }
    }

    private func load() async {
        guard found.isEmpty, pending == 0 else { return }
        let providers = addons.supporting("stream", type: target.type, id: target.videoId)
        let order = addons.addons.map(\.id)
        pending = providers.count
        await withTaskGroup(of: (InstalledAddon, [StreamItem]).self) { group in
            for addon in providers {
                group.addTask {
                    let streams = (try? await AddonClient.shared.streams(addon, type: target.type, videoId: target.videoId)) ?? []
                    return (addon, streams)
                }
            }
            for await (addon, streams) in group {
                let playable = streams.filter { $0.url != nil || $0.externalUrl != nil || $0.ytId != nil }
                torrentOnly += streams.count - playable.count
                let base = (order.firstIndex(of: addon.id) ?? 0) * 10_000
                found += playable.enumerated().map { Found(addon: addon, stream: $0.element, order: base + $0.offset) }
                pending -= 1
            }
        }
    }
}
