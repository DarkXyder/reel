import AVKit
import MobileVLCKit
import SwiftUI

/// Hosts the VLC video surface.
private struct VLCSurface: UIViewRepresentable {
    let model: PlayerModel

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        DispatchQueue.main.async { model.start(in: v) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Full-screen VLC player with auto-hiding controls, audio and subtitle menus.
struct PlayerScreen: View {
    @StateObject private var model: PlayerModel
    @EnvironmentObject private var addons: AddonStore
    @Environment(\.dismiss) private var dismiss
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?

    init(request: PlayRequest, library: LibraryStore) {
        _model = StateObject(wrappedValue: PlayerModel(request: request) { position, duration in
            library.recordProgress(request.meta, videoId: request.videoId, videoTitle: request.videoTitle,
                                   position: position, duration: duration)
        })
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCSurface(model: model).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if model.isBuffering && !model.failed {
                ProgressView().controlSize(.large).tint(.white)
            }
            if model.failed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("This stream couldn't be played.").font(.headline)
                    Button("Close") { close() }.buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
            }
            if showControls { controls.transition(.opacity) }
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .task { await loadSubtitles() }
        .onAppear { scheduleHide() }
        .onChange(of: model.ended) { ended in if ended { close() } }
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                HStack(spacing: 18) {
                    Button { close() } label: { Image(systemName: "xmark") }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.request.meta.name).font(.headline).lineLimit(1)
                        if let t = model.request.videoTitle {
                            Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    audioMenu
                    subtitleMenu
                }
                .font(.title3)
                .padding(.horizontal)

                Spacer()

                HStack(spacing: 56) {
                    Button { model.skip(-10); scheduleHide() } label: { Image(systemName: "gobackward.10") }
                    Button { model.togglePlay(); scheduleHide() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44))
                    }
                    Button { model.skip(30); scheduleHide() } label: { Image(systemName: "goforward.30") }
                }
                .font(.system(size: 30))

                Spacer()

                VStack(spacing: 4) {
                    Slider(value: Binding(
                        get: { scrubbing ?? (model.duration > 0 ? model.time / model.duration : 0) },
                        set: { scrubbing = $0 }
                    ), in: 0...1) { editing in
                        if !editing, let f = scrubbing {
                            model.seek(toFraction: f)
                            scrubbing = nil
                        }
                        scheduleHide()
                    }
                    HStack {
                        Text(format(scrubbing.map { $0 * model.duration } ?? model.time))
                        Spacer()
                        Text("-" + format(max(0, model.duration - (scrubbing.map { $0 * model.duration } ?? model.time))))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    private var audioMenu: some View {
        Menu {
            ForEach(model.audioTracks) { t in
                Button { model.selectAudio(t.id) } label: { checked(t.name, t.id == model.currentAudio) }
            }
        } label: { Image(systemName: "speaker.wave.2") }
        .disabled(model.audioTracks.count < 2)
    }

    private var subtitleMenu: some View {
        Menu {
            ForEach(model.subtitleTracks) { t in
                Button { model.selectSubtitle(t.id) } label: {
                    checked(t.id == -1 ? "Off" : t.name, t.id == model.currentSubtitle)
                }
            }
            if !model.externalSubtitles.isEmpty {
                Divider()
                ForEach(groupedExternal) { group in
                    Menu(Self.languageName(group.lang)) {
                        ForEach(Array(group.subs.prefix(10).enumerated()), id: \.element.identity) { i, sub in
                            Button("\(Self.languageName(group.lang)) \(i + 1)") { model.selectExternal(sub) }
                        }
                    }
                }
            }
        } label: { Image(systemName: "captions.bubble") }
    }

    private struct LangGroup: Identifiable {
        let lang: String
        let subs: [Subtitle]
        var id: String { lang }
    }

    @ViewBuilder
    private func checked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// Add-on subtitles by language, the phone's language first.
    private var groupedExternal: [LangGroup] {
        let groups = Dictionary(grouping: model.externalSubtitles, by: { $0.lang })
        let preferred = Locale.current.language.languageCode?.identifier ?? "en"
        return groups.map { LangGroup(lang: $0.key, subs: $0.value) }.sorted { a, b in
            let pa = Self.matches(a.lang, preferred), pb = Self.matches(b.lang, preferred)
            if pa != pb { return pa }
            return Self.languageName(a.lang) < Self.languageName(b.lang)
        }
    }

    private static func matches(_ lang: String, _ code: String) -> Bool {
        lang.lowercased().hasPrefix(code.lowercased()) || Locale(identifier: lang).language.languageCode?.identifier == code
    }

    private static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    @MainActor
    private func loadSubtitles() async {
        let req = model.request
        let providers = addons.supporting("subtitles", type: req.type, id: req.videoId)
        await withTaskGroup(of: [Subtitle].self) { group in
            for addon in providers {
                group.addTask { (try? await AddonClient.shared.subtitles(addon, type: req.type, videoId: req.videoId)) ?? [] }
            }
            for await subs in group {
                let known = Set(model.externalSubtitles.map(\.identity))
                model.externalSubtitles += subs.filter { !known.contains($0.identity) }
            }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled && model.isPlaying && scrubbing == nil {
                withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
            }
        }
    }

    private func close() {
        model.stop()
        dismiss()
    }

    private func format(_ t: Double) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Apple's player, for streams it can handle (MP4 / HLS). Gives native AirPlay to an Apple TV.
struct ApplePlayerScreen: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        vc.allowsPictureInPicturePlayback = true
        vc.player?.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: ()) {
        vc.player?.pause()
    }
}
