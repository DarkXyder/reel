import Foundation
import MediaPlayer
import UIKit

/// Picks one stream for a video without asking: the preferred add-on first, the same binge group
/// as the previous episode if possible, otherwise the best quality.
enum StreamPicker {
    struct Pick {
        let addon: InstalledAddon
        let stream: StreamItem
        let url: URL
    }

    @MainActor
    static func best(type: String, videoId: String, addons: AddonStore, preferAddon: String? = nil,
                     bingeGroup: String? = nil) async -> Pick? {
        var providers = addons.supporting("stream", type: type, id: videoId)
        for pref in [AppSettings.shared.preferredAddon, preferAddon].compactMap({ $0 }) {
            if let i = providers.firstIndex(where: { $0.id == pref }) { providers.insert(providers.remove(at: i), at: 0) }
        }
        for addon in providers {
            guard let streams = try? await AddonClient.shared.streams(addon, type: type, videoId: videoId) else { continue }
            let playable = streams.filter { $0.url != nil }
            let chosen = playable.first(where: { bingeGroup != nil && $0.behaviorHints?.bingeGroup == bingeGroup })
                ?? playable.max(by: { a, b in
                    a.quality != b.quality ? a.quality < b.quality : (a.sizeBytes ?? 0) < (b.sizeBytes ?? 0)
                })
            if let s = chosen, let u = s.url, let url = URL(string: u) { return Pick(addon: addon, stream: s, url: url) }
        }
        return nil
    }
}

extension Video {
    /// Season 1… in order, specials (season 0) last.
    static func ordered(_ videos: [Video]) -> [Video] {
        videos.sorted { a, b in
            let sa = a.season ?? 1, sb = b.season ?? 1
            if sa != sb { return sa == 0 ? false : (sb == 0 ? true : sa < sb) }
            return a.episodeNumber < b.episodeNumber
        }
    }

    /// Not out yet (release date in the future).
    var isUnreleased: Bool {
        guard let r = released else { return false }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: r) ?? ISO8601DateFormatter().date(from: r) else { return false }
        return d > Date()
    }
}

/// Lock screen / Control Center / headphone controls and the "Now Playing" card for VLC and Apple's player.
@MainActor
final class NowPlaying {
    struct Actions {
        let play: () -> Void
        let pause: () -> Void
        let skip: (Double) -> Void
        let seek: (Double) -> Void
    }

    private var targets: [(MPRemoteCommand, Any)] = []
    private var info: [String: Any] = [:]
    private var lastPush = Date.distantPast

    func activate(title: String, subtitle: String?, artwork: String?, actions: Actions) {
        let c = MPRemoteCommandCenter.shared()
        add(c.playCommand) { _ in Task { @MainActor in actions.play() }; return .success }
        add(c.pauseCommand) { _ in Task { @MainActor in actions.pause() }; return .success }
        add(c.togglePlayPauseCommand) { [weak self] _ in
            let playing = (self?.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0) > 0
            Task { @MainActor in playing ? actions.pause() : actions.play() }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.preferredIntervals = [10]
        add(c.skipForwardCommand) { _ in Task { @MainActor in actions.skip(30) }; return .success }
        add(c.skipBackwardCommand) { _ in Task { @MainActor in actions.skip(-10) }; return .success }
        add(c.changePlaybackPositionCommand) { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in actions.seek(t) }
            return .success
        }

        info = [MPMediaItemPropertyTitle: subtitle ?? title,
                MPMediaItemPropertyArtist: subtitle == nil ? "Reel" : title,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
                MPNowPlayingInfoPropertyPlaybackRate: 0.0]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let s = artwork, let url = URL(string: s) {
            Task { [weak self] in
                guard let result = try? await URLSession.shared.data(from: url), let image = UIImage(data: result.0) else { return }
                let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self?.info[MPMediaItemPropertyArtwork] = art
                if let info = self?.info { MPNowPlayingInfoCenter.default().nowPlayingInfo = info }
            }
        }
    }

    /// Cheap to call often: only pushes when playback state changes or every few seconds.
    func update(time: Double, duration: Double, playing: Bool, rate: Float = 1) {
        let newRate = playing ? Double(rate) : 0
        let changed = (info[MPNowPlayingInfoPropertyPlaybackRate] as? Double) != newRate
        guard changed || Date().timeIntervalSince(lastPush) > 5 else { return }
        lastPush = Date()
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = newRate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func deactivate() {
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func add(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        targets.append((command, command.addTarget(handler: handler)))
    }
}

/// "Up next": the episode after the last one you finished, for every series you're watching.
struct UpNextItem: Identifiable {
    let entry: LibraryEntry
    let video: Video
    let episodes: [Video]
    var id: String { video.id }
}

@MainActor
final class UpNextService: ObservableObject {
    static let shared = UpNextService()
    @Published private(set) var items: [UpNextItem] = []
    private var metaCache: [String: (MetaDetail, Date)] = [:]

    func refresh(library: LibraryStore, addons: AddonStore) async {
        let series = library.entries.values
            .filter { $0.type == "series" && !($0.videos ?? [:]).isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(20)
        var found: [UpNextItem] = []
        for entry in series {
            guard let latest = entry.videos?.max(by: { $0.value.updatedAt < $1.value.updatedAt }),
                  latest.value.isWatched, let meta = await meta(entry, addons: addons) else { continue }
            let lastId = latest.key
            let episodes = Video.ordered(meta.videos ?? [])
            guard let i = episodes.firstIndex(where: { $0.id == lastId }) else { continue }
            // The first following episode that's out and not already started or watched.
            if let next = episodes[(i + 1)...].first(where: { v in
                !v.isUnreleased && library.progress(metaId: entry.id, videoId: v.id) == nil
            }) {
                found.append(UpNextItem(entry: entry, video: next, episodes: episodes))
            }
        }
        items = found
    }

    private func meta(_ e: LibraryEntry, addons: AddonStore) async -> MetaDetail? {
        if let cached = metaCache[e.id], Date().timeIntervalSince(cached.1) < 6 * 3600 { return cached.0 }
        for addon in addons.supporting("meta", type: e.type, id: e.id) {
            if let m = try? await AddonClient.shared.meta(addon, type: e.type, id: e.id) {
                metaCache[e.id] = (m, Date())
                return m
            }
        }
        return nil
    }
}
