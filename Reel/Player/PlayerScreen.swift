import AVKit
import MobileVLCKit
import SwiftUI

/// Hosts the VLC video surface. It takes no touches: VLC's own video view would otherwise swallow
/// the taps that bring the controls back.
private struct VLCSurface: UIViewRepresentable {
    let model: PlayerModel

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async { model.start(in: v) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

enum VideoZoom: String, CaseIterable, Identifiable {
    case fit = "Fit"
    case fill = "Fill"
    var id: String { rawValue }
}

/// Full-screen VLC player: tap to show/hide controls, double-tap a side to skip 10 s,
/// settings panel for audio, subtitles, delays, speed and zoom.
struct PlayerScreen: View {
    @StateObject private var model: PlayerModel
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var nextDismissed = false
    @State private var findingNext = false
    private let onNext: (PlayRequest) -> Void
    private let onSwitch: (Double) -> Void
    @State private var showControls = true
    @State private var showSettings = false
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @State private var zoom: VideoZoom = .fit

    init(request: PlayRequest, library: LibraryStore, onNext: @escaping (PlayRequest) -> Void = { _ in },
         onSwitch: @escaping (Double) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: PlayerModel(request: request) { position, duration in
            library.recordProgress(request.meta, videoId: request.videoId, videoTitle: request.videoTitle,
                                   position: position, duration: duration)
        })
        self.onNext = onNext
        self.onSwitch = onSwitch
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VLCSurface(model: model)
                    .ignoresSafeArea()
                    .scaleEffect(zoomScale(screen: geo.size))
                    .clipped()

                // Tap layer: above the video, below the controls.
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .gesture(
                        SpatialTapGesture(count: 2).onEnded { tap in
                            model.skip(tap.location.x < geo.size.width / 2 ? -10 : 10)
                        }
                        .exclusively(before: TapGesture().onEnded { toggleControls() })
                    )

                if model.isBuffering && !model.failed {
                    ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
                }
                if model.failed {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text("This stream couldn't be played.").font(.headline)
                        Button("Close") { close() }.buttonStyle(.borderedProminent)
                    }
                    .foregroundStyle(.white)
                }
                if !model.failed {
                    EpisodeOverlay(request: model.request, time: model.time, duration: model.duration,
                                   skip: { model.skip(Int32($0)) }, playNext: playNext,
                                   nextDismissed: $nextDismissed, findingNext: $findingNext)
                }
                if showControls || !model.isPlaying {
                    controls.transition(.opacity)
                }
            }
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .task { await loadSubtitles() }
        .onAppear { scheduleHide() }
        .onChange(of: model.ended) { ended in
            guard ended else { return }
            if settings.autoPlayNext, !nextDismissed, NextEpisode.video(after: model.request) != nil { playNext() } else { close() }
        }
        .onDisappear { model.stop() }
        .onChange(of: model.isPlaying) { playing in
            if playing { scheduleHide() } else { withAnimation { showControls = true } }
        }
        .sheet(isPresented: $showSettings, onDismiss: scheduleHide) {
            PlayerSettingsSheet(model: model, zoom: $zoom, onAppleSwitch: switchToApple)
                .presentationDetents([.medium, .large])
        }
    }

    /// Fill crops the video to the screen; Fit shows all of it.
    private func zoomScale(screen: CGSize) -> CGFloat {
        guard zoom == .fill, model.videoSize.width > 0, screen.width > 0, screen.height > 0 else { return 1 }
        let videoAspect = model.videoSize.width / model.videoSize.height
        let screenAspect = screen.width / screen.height
        return max(videoAspect / screenAspect, screenAspect / videoAspect)
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                HStack(spacing: 20) {
                    Button { close() } label: { Image(systemName: "xmark").padding(8) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.request.meta.name).font(.headline).lineLimit(1)
                        if let t = model.request.videoTitle {
                            Text(t).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                    }
                    Spacer()
                    AirPlayButton().frame(width: 36, height: 36)
                    Button { openSettings() } label: { Image(systemName: "captions.bubble").padding(8) }
                    Button { openSettings() } label: { Image(systemName: "slider.horizontal.3").padding(8) }
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
                        if model.rate != 1 { Text(speedLabel(model.rate)) }
                        Spacer()
                        Text("-" + format(max(0, model.duration - (scrubbing.map { $0 * model.duration } ?? model.time))))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
        }
        .foregroundStyle(.white)
        .tint(.white)
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

    private func switchToApple() {
        showSettings = false
        let t = model.time
        model.stop()
        onSwitch(t)
    }

    private func openSettings() {
        hideTask?.cancel()
        showSettings = true
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled && model.isPlaying && scrubbing == nil && !showSettings {
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

func speedLabel(_ r: Float) -> String {
    r == 1 ? "Normal" : String(format: "%gx", r)
}

/// Audio, subtitles, delays, speed and zoom.
struct PlayerSettingsSheet: View {
    @ObservedObject var model: PlayerModel
    @Binding var zoom: VideoZoom
    var onAppleSwitch: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var expandedLang: String?

    private let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    if model.audioTracks.isEmpty {
                        Text("No audio tracks reported yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.audioTracks.filter { $0.id != -1 }) { t in
                        choice(t.name, selected: t.id == model.currentAudio) { model.selectAudio(t.id) }
                    }
                }

                Section("Subtitles") {
                    choice("Off", selected: model.currentSubtitle == -1 && model.selectedExternal == nil) {
                        model.selectSubtitle(-1)
                    }
                    ForEach(embeddedSubtitles) { t in
                        choice(t.name, selected: t.id == model.currentSubtitle && model.selectedExternal == nil) {
                            model.selectSubtitle(t.id)
                        }
                    }
                }

                if !model.externalSubtitles.isEmpty {
                    Section("Download subtitles") {
                        ForEach(groupedExternal) { group in
                            DisclosureGroup(isExpanded: Binding(
                                get: { expandedLang == group.lang },
                                set: { expandedLang = $0 ? group.lang : nil }
                            )) {
                                ForEach(Array(group.subs.prefix(15).enumerated()), id: \.element.identity) { i, sub in
                                    choice("\(languageName(group.lang)) \(i + 1)", selected: model.selectedExternal == sub.identity) {
                                        model.selectExternal(sub)
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(languageName(group.lang))
                                    Spacer()
                                    Text("\(group.subs.count)").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Subtitle size") {
                    Picker("Size", selection: Binding(get: { model.subtitleSize }, set: { model.setSubtitleSize($0) })) {
                        ForEach(SubtitleSize.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    stepperRow("Subtitle delay", value: model.subtitleDelay) { model.setSubtitleDelay($0) }
                    stepperRow("Audio delay", value: model.audioDelay) { model.setAudioDelay($0) }
                } footer: {
                    Text("Positive values make subtitles / sound come later.")
                }

                Section("Playback speed") {
                    Picker("Speed", selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
                        ForEach(speeds, id: \.self) { Text(speedLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Video") {
                    Picker("Zoom", selection: $zoom) {
                        ForEach(VideoZoom.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button { onAppleSwitch() } label: {
                        Label("Continue in Apple player", systemImage: "airplayvideo")
                    }
                } footer: {
                    Text("For AirPlay video to an Apple TV / AirPlay TV and picture-in-picture. Works with MP4 and HLS streams; MKV needs VLC. The AirPlay button in VLC sends sound only.")
                }
            }
            .navigationTitle("Playback settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    /// VLC lists "Disable" (-1) and, after loading add-on subtitles, those files too: show the rest here.
    private var embeddedSubtitles: [PlayerModel.Track] {
        let count = model.subtitleTracks.filter { $0.id != -1 }.count
        let external = min(model.loadedExternal.count, count)
        return Array(model.subtitleTracks.filter { $0.id != -1 }.prefix(count - external))
    }

    private struct LangGroup: Identifiable {
        let lang: String
        let subs: [Subtitle]
        var id: String { lang }
    }

    /// Add-on subtitles by language, the phone's language first.
    private var groupedExternal: [LangGroup] {
        let groups = Dictionary(grouping: model.externalSubtitles, by: { $0.lang })
        let preferred = Locale.current.language.languageCode?.identifier ?? "en"
        return groups.map { LangGroup(lang: $0.key, subs: $0.value) }.sorted { a, b in
            let pa = matches(a.lang, preferred), pb = matches(b.lang, preferred)
            if pa != pb { return pa }
            return languageName(a.lang) < languageName(b.lang)
        }
    }

    private func matches(_ lang: String, _ code: String) -> Bool {
        lang.lowercased().hasPrefix(code.lowercased()) || Locale(identifier: lang).language.languageCode?.identifier == code
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.reel) }
            }
        }
    }

    private func stepperRow(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button { set(value - 0.1) } label: { Image(systemName: "minus.circle.fill") }.buttonStyle(.borderless)
            Text(String(format: "%+.1f s", value)).monospacedDigit().frame(minWidth: 64)
            Button { set(value + 0.1) } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.borderless)
            Button("Reset") { set(0) }.buttonStyle(.borderless).font(.caption).disabled(value == 0)
        }
    }
}
