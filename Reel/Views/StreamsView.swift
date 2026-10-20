import SwiftUI
import UIKit

/// Streams for one movie or episode, from every installed add-on that offers streams.
struct StreamsView: View {
    let target: StreamTarget
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.openURL) private var openURL
    @State private var groups: [StreamGroup] = []
    @State private var pending = 0
    @State private var torrentOnly = 0
    @State private var playing: PlayRequest?
    @State private var applePlayer: URL?

    struct StreamGroup: Identifiable {
        let addon: InstalledAddon
        let streams: [StreamItem]
        var id: String { addon.id }
    }

    var body: some View {
        NavigationStack {
            List {
                if groups.isEmpty && pending == 0 {
                    EmptyState(icon: "play.slash", title: "No streams",
                               message: addons.supporting("stream", type: target.type, id: target.videoId).isEmpty
                                   ? "None of your add-ons provides streams for this. Add one in Settings → Add-ons."
                                   : "Your add-ons found nothing playable for this title.")
                        .listRowBackground(Color.clear)
                }
                ForEach(groups) { g in
                    Section(g.addon.manifest.name) {
                        ForEach(Array(g.streams.enumerated()), id: \.offset) { _, s in
                            row(s)
                        }
                    }
                }
                if torrentOnly > 0 {
                    Section {
                        Text("\(torrentOnly) torrent result(s) hidden: Reel plays direct links only.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { if pending > 0 && groups.isEmpty { ProgressView("Finding streams…") } }
            .navigationTitle(target.videoTitle ?? target.meta.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await load() }
        .fullScreenCover(item: $playing) { req in
            PlayerScreen(request: req, library: library).environmentObject(addons)
        }
        .fullScreenCover(item: $applePlayer) { url in
            ApplePlayerScreen(url: url).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func row(_ s: StreamItem) -> some View {
        Button { play(s) } label: {
            VStack(alignment: .leading, spacing: 3) {
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
                Button { applePlayer = url } label: { Label("Play with Apple player (AirPlay)", systemImage: "airplayvideo") }
                Button { openExternal("vlc-x-callback://x-callback-url/stream?url=", url) } label: { Label("Open in VLC", systemImage: "play.rectangle") }
                Button { openExternal("infuse://x-callback-url/play?url=", url) } label: { Label("Open in Infuse", systemImage: "play.rectangle") }
                Button { UIPasteboard.general.string = url.absoluteString } label: { Label("Copy link", systemImage: "doc.on.doc") }
            }
        }
    }

    private func play(_ s: StreamItem) {
        if let u = s.url, let url = URL(string: u) {
            playing = PlayRequest(url: url, meta: target.meta, type: target.type, videoId: target.videoId,
                                  videoTitle: target.videoTitle, streamSubtitles: s.subtitles ?? [],
                                  headers: s.behaviorHints?.proxyHeaders?.request ?? [:],
                                  resumeAt: library.resumePosition(metaId: target.meta.id, videoId: target.videoId))
        } else if let e = s.externalUrl, let url = URL(string: e) {
            openURL(url)
        } else if let yt = s.ytId, let url = URL(string: "https://www.youtube.com/watch?v=\(yt)") {
            openURL(url)
        }
    }

    private func openExternal(_ prefix: String, _ url: URL) {
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        if let u = URL(string: prefix + encoded) { openURL(u) }
    }

    private func load() async {
        guard groups.isEmpty, pending == 0 else { return }
        let providers = addons.supporting("stream", type: target.type, id: target.videoId)
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
                if !playable.isEmpty {
                    // keep the order of the add-ons in Settings
                    groups.append(StreamGroup(addon: addon, streams: playable))
                    let order = addons.addons.map(\.id)
                    groups.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
                }
                pending -= 1
            }
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
