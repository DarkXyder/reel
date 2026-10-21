import Foundation

/// Where you stopped in one video (a movie, an episode, a file).
struct VideoProgress: Codable, Hashable {
    var position: Double   // seconds
    var duration: Double   // seconds
    var updatedAt: Date

    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
    var isWatched: Bool { fraction >= 0.92 }
    /// Worth resuming: past the first half-minute and not finished.
    var isResumable: Bool { position > 30 && !isWatched }
}

/// One title the user saved or watched, with where they stopped.
struct LibraryEntry: Codable, Hashable, Identifiable {
    var id: String          // meta id, e.g. "tt0944947"
    var type: String
    var name: String
    var poster: String?
    var background: String?
    var inLibrary: Bool
    var lastVideoId: String?   // episode id for series ("tt0944947:1:2"), meta id for movies
    var lastVideoTitle: String?
    var position: Double       // seconds, in lastVideoId
    var duration: Double       // seconds
    var updatedAt: Date
    /// Progress of every video of this title, by video id. Optional so older saves still load.
    var videos: [String: VideoProgress]?

    var progress: Double { duration > 0 ? min(1, position / duration) : 0 }

    /// Started but not finished.
    var isInProgress: Bool { position > 60 && progress < 0.92 }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var entries: [String: LibraryEntry] = [:]

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: LibraryEntry].self, from: data) {
            entries = saved
        }
    }

    var library: [LibraryEntry] {
        entries.values.filter(\.inLibrary).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var continueWatching: [LibraryEntry] {
        entries.values.filter(\.isInProgress).sorted { $0.updatedAt > $1.updatedAt }
    }

    func isInLibrary(_ id: String) -> Bool { entries[id]?.inLibrary == true }

    func toggleLibrary(_ meta: MetaPreview) {
        var e = entry(for: meta)
        e.inLibrary.toggle()
        e.updatedAt = Date()
        entries[meta.id] = e
        save()
    }

    /// Saved progress of one video, if it was played.
    func progress(metaId: String, videoId: String) -> VideoProgress? {
        guard let e = entries[metaId] else { return nil }
        if let p = e.videos?[videoId] { return p }
        // saves from before per-video tracking
        if e.lastVideoId == videoId, e.duration > 0 {
            return VideoProgress(position: e.position, duration: e.duration, updatedAt: e.updatedAt)
        }
        return nil
    }

    /// Where to resume this video, if it was left part-way.
    func resumePosition(metaId: String, videoId: String) -> Double? {
        guard let p = progress(metaId: metaId, videoId: videoId), p.isResumable else { return nil }
        return p.position
    }

    func recordProgress(_ meta: MetaPreview, videoId: String, videoTitle: String?, position: Double, duration: Double) {
        guard duration > 0 else { return }
        var e = entry(for: meta)
        e.lastVideoId = videoId
        e.lastVideoTitle = videoTitle
        e.position = position
        e.duration = duration
        e.updatedAt = Date()
        var videos = e.videos ?? [:]
        videos[videoId] = VideoProgress(position: position, duration: duration, updatedAt: e.updatedAt)
        e.videos = videos
        entries[meta.id] = e
        save()
    }

    /// Progress from another device (Trakt). Doesn't move "last watched" back in time.
    func importProgress(_ meta: MetaPreview, videoId: String, videoTitle: String?, position: Double,
                        duration: Double, date: Date) {
        guard duration > 0 else { return }
        var e = entry(for: meta)
        if e.poster == nil { e.poster = meta.poster; e.background = meta.background }
        if e.name == e.id { e.name = meta.name }
        var videos = e.videos ?? [:]
        videos[videoId] = VideoProgress(position: position, duration: duration, updatedAt: date)
        e.videos = videos
        if date >= e.updatedAt || e.lastVideoId == nil {
            e.lastVideoId = videoId
            e.lastVideoTitle = videoTitle
            e.position = position
            e.duration = duration
            e.updatedAt = date
        }
        entries[meta.id] = e
        save()
    }

    func clearProgress(_ id: String) {
        guard var e = entries[id] else { return }
        e.position = 0
        entries[id] = e
        save()
    }

    private func entry(for meta: MetaPreview) -> LibraryEntry {
        entries[meta.id] ?? LibraryEntry(id: meta.id, type: meta.type, name: meta.name, poster: meta.poster,
                                         background: meta.background, inLibrary: false, lastVideoId: nil,
                                         lastVideoTitle: nil, position: 0, duration: 0, updatedAt: Date(), videos: nil)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

extension LibraryEntry {
    var preview: MetaPreview {
        MetaPreview(id: id, type: type, name: name, poster: poster, posterShape: nil, background: background,
                    logo: nil, description: nil, releaseInfo: nil, imdbRating: nil)
    }
}
