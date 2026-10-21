import AVFoundation
import Foundation
import MobileVLCKit
import UIKit

/// Everything needed to start playback, created by the streams list.
struct PlayRequest: Identifiable {
    var id = UUID()
    let url: URL
    let meta: MetaPreview
    let type: String
    let videoId: String
    let videoTitle: String?
    let streamSubtitles: [Subtitle]
    let headers: [String: String]
    var resumeAt: Double?
    /// Add-on and binge group the stream came from: the next episode is taken from the same place.
    var addonId: String? = nil
    var bingeGroup: String? = nil
    /// "mkv", "mp4", "m3u8"… decides between VLC and Apple's player in Auto mode.
    var fileExtension: String? = nil
    /// All episodes of the series in order (empty for movies), for "next episode".
    var episodes: [Video] = []
    /// Set when the user switches player mid-video.
    var forcePlayer: PlayerMode? = nil

    var isEpisode: Bool { !episodes.isEmpty }
}

/// Subtitle text size, remembered across videos.
enum SubtitleSize: String, CaseIterable, Identifiable {
    case small = "Small", normal = "Normal", large = "Large", extraLarge = "Extra large"
    var id: String { rawValue }

    /// VLC's --sub-text-scale, in percent (applied when a video starts).
    var scale: Int {
        switch self { case .small: return 75; case .normal: return 100; case .large: return 135; case .extraLarge: return 175 }
    }

    /// VLC's relative font size (smaller number = bigger text), used to change it during playback.
    var relativeFontSize: Int {
        switch self { case .small: return 20; case .normal: return 16; case .large: return 12; case .extraLarge: return 9 }
    }

    static var saved: SubtitleSize {
        SubtitleSize(rawValue: UserDefaults.standard.string(forKey: "subtitleSize") ?? "") ?? .normal
    }
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
    @Published private(set) var selectedExternal: String?
    @Published private(set) var rate: Float = 1
    @Published private(set) var subtitleDelay: Double = 0   // seconds, + = later
    @Published private(set) var audioDelay: Double = 0      // seconds, + = later
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var subtitleSize: SubtitleSize = .saved

    private var timer: Timer?
    private var background: NSObjectProtocol?
    private lazy var reporter = PlaybackReporter(request: request)
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
        media.addOption(":sub-text-scale=\(subtitleSize.scale)")
        media.addOption(":freetype-rel-fontsize=\(subtitleSize.relativeFontSize)")
        if let resume = request.resumeAt, resume > 5 {
            media.addOption(":start-time=\(Int(resume))")
        }
        player.drawable = view
        player.media = media
        player.play()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Save where we are if the app is sent to the background or closed.
        background = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.saveProgress(force: true) }
        }
    }

    func stop() {
        guard timer != nil else { return } // already stopped
        saveProgress(force: true)
        reporter.stop(fraction: duration > 0 ? time / duration : 0)
        timer?.invalidate()
        timer = nil
        if let background { NotificationCenter.default.removeObserver(background) }
        background = nil
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
        selectedExternal = nil
    }

    func setSubtitleSize(_ size: SubtitleSize) {
        subtitleSize = size
        UserDefaults.standard.set(size.rawValue, forKey: "subtitleSize")
        // Live change; VLCKit 3 exposes this as -setTextRendererFontSize:.
        let sel = NSSelectorFromString("setTextRendererFontSize:")
        if player.responds(to: sel) {
            player.perform(sel, with: NSNumber(value: size.relativeFontSize))
        }
        // Re-select the current subtitle track so it is redrawn at the new size.
        let current = player.currentVideoSubTitleIndex
        if current != -1 {
            player.currentVideoSubTitleIndex = -1
            player.currentVideoSubTitleIndex = current
        }
    }

    func setRate(_ r: Float) {
        player.rate = r
        rate = r
    }

    func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = (seconds * 10).rounded() / 10
        player.currentVideoSubTitleDelay = Int(subtitleDelay * 1_000_000) // microseconds
    }

    func setAudioDelay(_ seconds: Double) {
        audioDelay = (seconds * 10).rounded() / 10
        player.currentAudioPlaybackDelay = Int(audioDelay * 1_000_000) // microseconds
    }

    /// External subtitles from add-ons are loaded into VLC only when picked.
    func selectExternal(_ sub: Subtitle) {
        guard let url = URL(string: sub.url) else { return }
        if !loadedExternal.contains(sub.identity) {
            // VLC appends the file as a new subtitle track and switches to it.
            player.addPlaybackSlave(url, type: .subtitle, enforce: true)
            loadedExternal.insert(sub.identity)
        } else if let t = subtitleTracks.last {
            player.currentVideoSubTitleIndex = t.id
        }
        selectedExternal = sub.identity
    }

    private func tick() {
        let ms = Double(player.time.intValue)
        let len = Double(player.media?.length.intValue ?? 0)
        time = max(0, ms / 1000)
        duration = max(0, len / 1000)
        isPlaying = player.isPlaying
        if duration > 0 { reporter.update(playing: isPlaying, fraction: time / duration) }
        switch player.state {
        case .buffering, .opening: isBuffering = !player.isPlaying
        case .error: failed = true; isBuffering = false
        case .ended:
            if !ended, duration > 0 { onProgress(duration, duration) } // finished: mark as watched
            ended = true; isBuffering = false
        default: isBuffering = false
        }
        let size = player.videoSize
        if size.width > 0 && size.height > 0 && size != videoSize { videoSize = size }
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
        if force || abs(time - lastSaved) >= 5 {
            lastSaved = time
            onProgress(time, duration)
        }
    }
}
