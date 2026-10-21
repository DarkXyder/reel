import AVKit
import SwiftUI

/// AVPlayer with watch progress, Trakt scrobbling, picture-in-picture and AirPlay video.
@MainActor
final class ApplePlayerModel: ObservableObject {
    let player: AVPlayer
    let request: PlayRequest

    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var failed: String?
    @Published private(set) var ended = false

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var lastSaved: Double = 0
    private let onProgress: (Double, Double) -> Void
    private lazy var reporter = PlaybackReporter(request: request)
    private var stopped = false
    private let nowPlaying = NowPlaying()
    private var lifecycle: [NSObjectProtocol] = []
    /// The on-screen controller; detached from the player in the background so sound keeps going.
    weak var controller: AVPlayerViewController?
    var pictureInPictureActive = false

    init(request: PlayRequest, onProgress: @escaping (Double, Double) -> Void) {
        self.request = request
        self.onProgress = onProgress
        let options: [String: Any]? = request.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": request.headers]
        let item = AVPlayerItem(asset: AVURLAsset(url: request.url, options: options))
        player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true

        if let resume = request.resumeAt, resume > 5 {
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600),
                                                      queue: .main) { [weak self] t in
            Task { @MainActor in self?.tick(t.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didEnd() }
        }
        statusObserver = item.observe(\.status) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor in
                if failed { self?.failed = "Apple's player can't play this format." }
            }
        }
    }

    func start() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        nowPlaying.activate(title: request.meta.name, subtitle: request.videoTitle, artwork: request.meta.poster,
                            actions: .init(play: { [weak self] in self?.player.play() },
                                           pause: { [weak self] in self?.player.pause() },
                                           skip: { [weak self] in self?.skip($0) },
                                           seek: { [weak self] in self?.player.seek(to: CMTime(seconds: $0, preferredTimescale: 600)) }))
        let nc = NotificationCenter.default
        lifecycle.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.enteredBackground() }
        })
        lifecycle.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.controller?.player = self?.player }
        })
    }

    private func enteredBackground() {
        guard !pictureInPictureActive else { return }
        if AppSettings.shared.backgroundAudio {
            controller?.player = nil // video layers pause in the background; detached, the sound continues
        } else {
            player.pause()
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        save(force: true)
        reporter.stop(fraction: duration > 0 ? time / duration : 0)
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObserver = nil
        lifecycle.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycle.removeAll()
        nowPlaying.deactivate()
    }

    func skip(_ seconds: Double) {
        let target = max(0, time + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        time = t
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        if duration > 0 {
            reporter.update(playing: player.rate > 0, fraction: time / duration)
            nowPlaying.update(time: time, duration: duration, playing: player.rate > 0, rate: player.rate)
        }
        save(force: false)
    }

    private func didEnd() {
        if duration > 0 { onProgress(duration, duration) }
        ended = true
    }

    private func save(force: Bool) {
        guard duration > 0, time > 0 else { return }
        if force || abs(time - lastSaved) >= 5 {
            lastSaved = time
            onProgress(time, duration)
        }
    }
}

private struct AVPlayerControllerView: UIViewControllerRepresentable {
    let model: ApplePlayerModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = model.player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.updatesNowPlayingInfoCenter = false // Reel fills in title, artwork and controls itself
        vc.delegate = context.coordinator
        model.controller = vc
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let model: ApplePlayerModel
        init(model: ApplePlayerModel) { self.model = model }

        func playerViewControllerDidStartPictureInPicture(_ vc: AVPlayerViewController) {
            Task { @MainActor in self.model.pictureInPictureActive = true }
        }

        func playerViewControllerDidStopPictureInPicture(_ vc: AVPlayerViewController) {
            Task { @MainActor in self.model.pictureInPictureActive = false }
        }
    }
}

/// Apple's player screen: system controls (AirPlay, picture-in-picture, speed, subtitles for HLS),
/// plus a top bar with close and "Play with VLC".
struct ApplePlayerScreen: View {
    @StateObject private var model: ApplePlayerModel
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var nextDismissed = false
    @State private var findingNext = false
    private let onNext: (PlayRequest) -> Void
    private let onSwitch: (Double) -> Void

    init(request: PlayRequest, library: LibraryStore, onNext: @escaping (PlayRequest) -> Void,
         onSwitch: @escaping (Double) -> Void) {
        _model = StateObject(wrappedValue: ApplePlayerModel(request: request) { position, duration in
            library.recordProgress(request.meta, videoId: request.videoId, videoTitle: request.videoTitle,
                                   position: position, duration: duration)
        })
        self.onNext = onNext
        self.onSwitch = onSwitch
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { close() } label: { Image(systemName: "xmark").font(.headline).padding(8) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.request.meta.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let t = model.request.videoTitle {
                        Text(t).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    let t = model.time
                    model.stop()
                    onSwitch(t)
                } label: { Label("VLC", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.semibold)) }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(Color.black)

            ZStack {
                AVPlayerControllerView(model: model)
                if let failed = model.failed {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(failed).font(.headline).multilineTextAlignment(.center)
                        Button("Play with VLC") { model.stop(); onSwitch(model.time) }.buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                } else {
                    EpisodeOverlay(request: model.request, time: model.time, duration: model.duration,
                                   skip: { model.skip($0) }, playNext: playNext,
                                   nextDismissed: $nextDismissed, findingNext: $findingNext)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.ended) { ended in
            guard ended else { return }
            if settings.autoPlayNext, !nextDismissed, NextEpisode.video(after: model.request) != nil { playNext() } else { close() }
        }
    }

    private func playNext() {
        guard !findingNext else { return }
        findingNext = true
        Task {
            let next = await NextEpisode.request(after: model.request, addons: addons, library: library)
            findingNext = false
            if let next {
                model.stop()
                onNext(next)
            } else if model.ended {
                close()
            } else {
                nextDismissed = true
            }
        }
    }

    private func close() {
        model.stop()
        dismiss()
    }
}
