import AVKit
import SwiftUI

/// Picks VLC or Apple's player for a request, and swaps in the next episode or the other player
/// without closing the full-screen cover.
struct PlayerHost: View {
    @State private var current: PlayRequest
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    init(request: PlayRequest) {
        _current = State(initialValue: request)
    }

    var body: some View {
        Group {
            if PlayerChoice.useApple(current, mode: settings.playerMode) {
                ApplePlayerScreen(request: current, library: library, onNext: { current = $0 },
                                  onSwitch: { switchPlayer(to: .vlc, at: $0) })
            } else {
                PlayerScreen(request: current, library: library, onNext: { current = $0 },
                             onSwitch: { switchPlayer(to: .apple, at: $0) })
            }
        }
        .id(current.id)
        .preferredColorScheme(.dark) // the player stays dark in Light mode too
    }

    private func switchPlayer(to mode: PlayerMode, at time: Double) {
        var r = current
        r.id = UUID()
        r.resumeAt = time
        r.forcePlayer = mode
        current = r
    }
}

enum PlayerChoice {
    /// Formats AVPlayer plays natively.
    static let appleFormats: Set<String> = ["mp4", "m4v", "mov", "m3u8", "mp3", "m4a"]

    static func useApple(_ r: PlayRequest, mode: PlayerMode) -> Bool {
        if let forced = r.forcePlayer { return forced == .apple }
        switch mode {
        case .vlc: return false
        case .apple: return true
        case .auto:
            let ext = (r.fileExtension ?? r.url.pathExtension).lowercased()
            return appleFormats.contains(ext)
        }
    }
}

/// Finds the episode after the one playing, and a stream for it from the same add-on.
enum NextEpisode {
    static func video(after r: PlayRequest) -> Video? {
        guard let i = r.episodes.firstIndex(where: { $0.id == r.videoId }), i + 1 < r.episodes.count else { return nil }
        return r.episodes[i + 1]
    }

    static func title(_ v: Video) -> String {
        "S\(v.season ?? 1)E\(v.episodeNumber) · \(v.displayTitle)"
    }

    @MainActor
    static func request(after r: PlayRequest, addons: AddonStore, library: LibraryStore) async -> PlayRequest? {
        guard let next = video(after: r) else { return nil }
        // A downloaded copy wins: works offline too.
        if let local = DownloadManager.shared.record(forVideo: next.id) {
            var req = PlayRequest(url: DownloadManager.shared.localURL(local), meta: r.meta, type: r.type, videoId: next.id,
                                  videoTitle: title(next), streamSubtitles: [], headers: [:],
                                  resumeAt: library.resumePosition(metaId: r.meta.id, videoId: next.id))
            req.fileExtension = local.fileExtension
            req.episodes = r.episodes
            return req
        }
        guard let pick = await StreamPicker.best(type: r.type, videoId: next.id, addons: addons,
                                                 preferAddon: r.addonId, bingeGroup: r.bingeGroup) else { return nil }
        let s = pick.stream
        var req = PlayRequest(url: pick.url, meta: r.meta, type: r.type, videoId: next.id, videoTitle: title(next),
                              streamSubtitles: s.subtitles ?? [], headers: s.behaviorHints?.proxyHeaders?.request ?? [:],
                              resumeAt: library.resumePosition(metaId: r.meta.id, videoId: next.id))
        req.addonId = pick.addon.id
        req.bingeGroup = s.behaviorHints?.bingeGroup
        req.fileExtension = s.fileExtension
        req.episodes = r.episodes
        return req
    }
}

/// "Skip intro" early in an episode and "Next episode" near its end. Shared by both players.
struct EpisodeOverlay: View {
    let request: PlayRequest
    let time: Double
    let duration: Double
    let skip: (Double) -> Void
    let playNext: () -> Void
    @Binding var nextDismissed: Bool
    @Binding var findingNext: Bool
    @EnvironmentObject private var settings: AppSettings
    @State private var introSkipped = false

    private var remaining: Double { duration - time }
    private var hasNext: Bool { NextEpisode.video(after: request) != nil }

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if findingNext {
                    Label("Finding next episode…", systemImage: "hourglass").pill()
                } else if hasNext, !nextDismissed, duration > 120, remaining > 0, remaining < 30,
                          let next = NextEpisode.video(after: request) {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(settings.autoPlayNext ? "Next episode in \(Int(remaining))s" : "Up next")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                        Text(NextEpisode.title(next)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        HStack {
                            Button("Cancel") { nextDismissed = true }.buttonStyle(.bordered)
                            Button { playNext() } label: { Label("Play now", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                } else if request.isEpisode, settings.skipIntroSeconds > 0, !introSkipped,
                          time > 3, time < min(600, max(0, duration * 0.3)) {
                    Button {
                        introSkipped = true
                        skip(Double(settings.skipIntroSeconds))
                    } label: {
                        Label("Skip intro", systemImage: "forward.fill").pill()
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 90)
        }
        .foregroundStyle(.white)
        .tint(Color.reel)
    }
}

private extension View {
    func pill() -> some View {
        font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
    }
}

/// The system AirPlay button.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(AppSettings.shared.accent.color)
        v.prioritizesVideoDevices = true
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
