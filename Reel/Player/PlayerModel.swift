import AVFoundation
import Foundation
import MobileVLCKit
import UIKit

/// Everything needed to start playback, created by the streams list.
struct PlayRequest: Identifiable {
    let id = UUID()
    let url: URL
    let meta: MetaPreview
    let type: String
    let videoId: String
    let videoTitle: String?
    let streamSubtitles: [Subtitle]
    let headers: [String: String]
    let resumeAt: Double?
}

/// Wraps VLCMediaPlayer. Polls twice a second instead of using delegate callbacks: simpler, and the
/// cost is negligible next to video decoding.
@MainActor
final class PlayerModel: ObservableObject {
    struct Track: Identifiable, Hashable {
        let id: Int32
        let name: String
    }

    let player = VLCMediaPlayer()
    let request: PlayRequest

    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var failed = false
    @Published private(set) var ended = false
    @Published private(set) var audioTracks: [Track] = []
    @Published private(set) var subtitleTracks: [Track] = []
    @Published private(set) var currentAudio: Int32 = -1
    @Published private(set) var currentSubtitle: Int32 = -1
    @Published var externalSubtitles: [Subtitle] = []
    @Published private(set) var loadedExternal: Set<String> = []

    private var timer: Timer?
    private var lastSaved: Double = 0
    private let onProgress: (Double, Double) -> Void

    init(request: PlayRequest, onProgress: @escaping (Double, Double) -> Void) {
        self.request = request
        self.onProgress = onProgress
        externalSubtitles = request.streamSubtitles
    }

    func start(in view: UIView) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let media = VLCMedia(url: request.url)
        if let ua = request.headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
            media.addOption(":http-user-agent=\(ua)")
        }
        if let ref = request.headers.first(where: { $0.key.lowercased() == "referer" })?.value {
            media.addOption(":http-referrer=\(ref)")
        }
        media.addOption(":network-caching=3000")
        if let resume = request.resumeAt, resume > 5 {
            media.addOption(":start-time=\(Int(resume))")
        }
        player.drawable = view
        player.media = media
        player.play()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        saveProgress(force: true)
        timer?.invalidate()
        timer = nil
        player.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func skip(_ seconds: Int32) {
        if seconds >= 0 { player.jumpForward(seconds) } else { player.jumpBackward(-seconds) }
    }

    func seek(toFraction f: Double) {
        player.position = Float(max(0, min(1, f)))
    }

    func selectAudio(_ id: Int32) {
        player.currentAudioTrackIndex = id
        currentAudio = id
    }

    func selectSubtitle(_ id: Int32) {
        player.currentVideoSubTitleIndex = id
        currentSubtitle = id
    }

    /// External subtitles from add-ons are loaded into VLC only when picked.
    func selectExternal(_ sub: Subtitle) {
        guard let url = URL(string: sub.url) else { return }
        if !loadedExternal.contains(sub.identity) {
            player.addPlaybackSlave(url, type: .subtitle, enforce: true)
            loadedExternal.insert(sub.identity)
        } else if let t = subtitleTracks.last {
            selectSubtitle(t.id)
        }
    }

    private func tick() {
        let ms = Double(player.time.intValue)
        let len = Double(player.media?.length.intValue ?? 0)
        time = max(0, ms / 1000)
        duration = max(0, len / 1000)
        isPlaying = player.isPlaying
        switch player.state {
        case .buffering, .opening: isBuffering = !player.isPlaying
        case .error: failed = true; isBuffering = false
        case .ended: ended = true; isBuffering = false
        default: isBuffering = false
        }
        refreshTracks()
        saveProgress(force: false)
    }

    private func refreshTracks() {
        audioTracks = Self.tracks(names: player.audioTrackNames, ids: player.audioTrackIndexes)
        subtitleTracks = Self.tracks(names: player.videoSubTitlesNames, ids: player.videoSubTitlesIndexes)
        currentAudio = player.currentAudioTrackIndex
        currentSubtitle = player.currentVideoSubTitleIndex
    }

    private static func tracks(names: [Any]?, ids: [Any]?) -> [Track] {
        guard let names, let ids else { return [] }
        return zip(names, ids).compactMap { name, id in
            guard let n = id as? NSNumber else { return nil }
            return Track(id: n.int32Value, name: (name as? String) ?? "Track \(n.int32Value)")
        }
    }

    private func saveProgress(force: Bool) {
        guard duration > 0, time > 0 else { return }
        if force || abs(time - lastSaved) >= 10 {
            lastSaved = time
            onProgress(time, duration)
        }
    }
}
