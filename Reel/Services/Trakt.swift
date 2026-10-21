import Foundation

/// Trakt.tv sync: device-code login, scrobbling what you watch (Trakt marks it watched past 80 %),
/// and importing paused positions so you can resume what you started on another device.
///
/// Trakt needs an API app of your own: create one at https://trakt.tv/oauth/applications/new
/// (redirect URI `urn:ietf:wg:oauth:2.0:oob`) and paste its Client ID and Secret in Settings.
@MainActor
final class TraktService: ObservableObject {
    static let shared = TraktService()

    struct DeviceCode: Decodable {
        let device_code: String
        let user_code: String
        let verification_url: String
        let expires_in: Int
        let interval: Int
    }

    @Published var clientId: String { didSet { UserDefaults.standard.set(clientId, forKey: "trakt.clientId") } }
    @Published private(set) var username: String?
    @Published private(set) var pendingCode: DeviceCode?
    @Published private(set) var status: String?
    @Published private(set) var lastImport: Date?

    private let api = "https://api.trakt.tv"
    private let redirect = "urn:ietf:wg:oauth:2.0:oob"

    private init() {
        clientId = UserDefaults.standard.string(forKey: "trakt.clientId") ?? ""
        username = UserDefaults.standard.string(forKey: "trakt.username")
    }

    var clientSecret: String { Keychain.get("trakt.secret") ?? "" }
    var hasCredentials: Bool { !clientId.isEmpty && !clientSecret.isEmpty }
    var isConnected: Bool { Keychain.get("trakt.access") != nil }

    func setSecret(_ s: String) {
        Keychain.set(s.trimmingCharacters(in: .whitespacesAndNewlines), for: "trakt.secret")
        objectWillChange.send()
    }

    // MARK: - login

    /// Shows a code to enter at trakt.tv/activate, then waits until you approve it.
    func connect() async {
        guard hasCredentials else { status = "Enter your Client ID and Secret first."; return }
        do {
            let code: DeviceCode = try await post("/oauth/device/code", ["client_id": clientId], auth: false)
            pendingCode = code
            status = nil
            let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
            var wait = UInt64(max(1, code.interval))
            while Date() < deadline, pendingCode != nil {
                try await Task.sleep(nanoseconds: wait * 1_000_000_000)
                let (data, http) = try await raw("/oauth/device/token", method: "POST",
                                                 body: ["code": code.device_code, "client_id": clientId, "client_secret": clientSecret],
                                                 auth: false)
                switch http.statusCode {
                case 200:
                    try storeTokens(data)
                    pendingCode = nil
                    await loadUser()
                    return
                case 400: continue          // waiting for you to approve
                case 429: wait += 1; continue // polling too fast
                default:
                    pendingCode = nil
                    status = "Trakt refused the login (HTTP \(http.statusCode))."
                    return
                }
            }
            if pendingCode != nil { status = "The code expired. Try again." }
            pendingCode = nil
        } catch {
            pendingCode = nil
            status = error.localizedDescription
        }
    }

    func cancelConnect() { pendingCode = nil }

    func disconnect() {
        Keychain.set(nil, for: "trakt.access")
        Keychain.set(nil, for: "trakt.refresh")
        username = nil
        UserDefaults.standard.removeObject(forKey: "trakt.username")
        objectWillChange.send()
    }

    private func storeTokens(_ data: Data) throws {
        struct T: Decodable { let access_token: String; let refresh_token: String }
        let t = try JSONDecoder().decode(T.self, from: data)
        Keychain.set(t.access_token, for: "trakt.access")
        Keychain.set(t.refresh_token, for: "trakt.refresh")
        objectWillChange.send()
    }

    private func refreshTokens() async -> Bool {
        guard let refresh = Keychain.get("trakt.refresh") else { return false }
        guard let result = try? await raw("/oauth/token", method: "POST", body: [
            "refresh_token": refresh, "client_id": clientId, "client_secret": clientSecret,
            "redirect_uri": redirect, "grant_type": "refresh_token",
        ], auth: false), result.1.statusCode == 200 else { return false }
        return (try? storeTokens(result.0)) != nil
    }

    private func loadUser() async {
        struct S: Decodable { let user: U }
        struct U: Decodable { let username: String }
        if let s: S = try? await get("/users/settings") {
            username = s.user.username
            UserDefaults.standard.set(s.user.username, forKey: "trakt.username")
        }
    }

    // MARK: - scrobble

    /// action: "start", "pause" or "stop". Only titles with IMDb ids (Cinemeta) can be matched.
    func scrobble(_ action: String, request: PlayRequest, progress: Double) async {
        guard isConnected, let body = Self.item(for: request, progress: progress) else { return }
        _ = try? await raw("/scrobble/\(action)", method: "POST", body: body, auth: true)
    }

    private static func item(for r: PlayRequest, progress: Double) -> [String: Any]? {
        let p = max(0, min(100, progress))
        let parts = r.videoId.split(separator: ":")
        guard let imdb = parts.first.map(String.init), imdb.hasPrefix("tt") else { return nil }
        if parts.count >= 3, let s = Int(parts[1]), let e = Int(parts[2]) {
            return ["show": ["ids": ["imdb": imdb]], "episode": ["season": s, "number": e], "progress": p]
        }
        return ["movie": ["ids": ["imdb": imdb]], "progress": p]
    }

    // MARK: - import

    /// Pulls paused positions from Trakt into the library. Returns how many were imported.
    @discardableResult
    func importProgress(into library: LibraryStore, addons: AddonStore) async -> Int {
        guard isConnected else { return 0 }
        struct Ids: Decodable { let imdb: String? }
        struct Movie: Decodable { let title: String?; let runtime: Int?; let ids: Ids }
        struct Show: Decodable { let title: String?; let ids: Ids }
        struct Episode: Decodable { let season: Int; let number: Int; let title: String?; let runtime: Int? }
        struct Item: Decodable {
            let progress: Double; let paused_at: String; let type: String
            let movie: Movie?; let show: Show?; let episode: Episode?
        }
        guard let items: [Item] = try? await get("/sync/playback?extended=full&limit=40") else {
            status = "Couldn't read your Trakt progress."
            return 0
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var count = 0
        for it in items {
            let date = iso.date(from: it.paused_at) ?? Date()
            var metaId: String, type: String, videoId: String, name: String, videoTitle: String?, runtime: Int
            if it.type == "movie", let m = it.movie, let imdb = m.ids.imdb {
                metaId = imdb; type = "movie"; videoId = imdb; name = m.title ?? imdb; runtime = m.runtime ?? 110
            } else if let s = it.show, let e = it.episode, let imdb = s.ids.imdb {
                metaId = imdb; type = "series"; videoId = "\(imdb):\(e.season):\(e.number)"; name = s.title ?? imdb
                videoTitle = "S\(e.season)E\(e.number) · \(e.title ?? "Episode \(e.number)")"; runtime = e.runtime ?? 45
            } else { continue }
            if let local = library.progress(metaId: metaId, videoId: videoId), local.updatedAt >= date { continue }
            let duration = Double(max(1, runtime) * 60)
            var meta = MetaPreview(id: metaId, type: type, name: name, poster: nil, posterShape: nil, background: nil,
                                   logo: nil, description: nil, releaseInfo: nil, imdbRating: nil)
            if library.entries[metaId]?.poster == nil, let addon = addons.supporting("meta", type: type, id: metaId).first,
               let full = try? await AddonClient.shared.meta(addon, type: type, id: metaId) {
                meta = full.preview
            }
            library.importProgress(meta, videoId: videoId, videoTitle: videoTitle,
                                   position: it.progress / 100 * duration, duration: duration, date: date)
            count += 1
        }
        lastImport = Date()
        return count
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, http) = try await raw(path, method: "GET", body: nil, auth: true)
        guard (200..<300).contains(http.statusCode) else { throw DebridError.http(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: Any], auth: Bool) async throws -> T {
        let (data, http) = try await raw(path, method: "POST", body: body, auth: auth)
        guard (200..<300).contains(http.statusCode) else { throw DebridError.http(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func raw(_ path: String, method: String, body: [String: Any]?, auth: Bool, retried: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: URL(string: api + path)!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2", forHTTPHeaderField: "trakt-api-version")
        req.setValue(clientId, forHTTPHeaderField: "trakt-api-key")
        if auth, let token = Keychain.get("trakt.access") {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw DebridError.http(0) }
        if http.statusCode == 401, auth, !retried, await refreshTokens() {
            return try await raw(path, method: method, body: body, auth: auth, retried: true)
        }
        return (data, http)
    }
}

/// Sends Trakt "start / pause / stop" as playback changes, without repeating itself.
@MainActor
final class PlaybackReporter {
    private let request: PlayRequest
    private var lastPlaying: Bool?

    init(request: PlayRequest) { self.request = request }

    func update(playing: Bool, fraction: Double) {
        guard playing != lastPlaying else { return }
        lastPlaying = playing
        send(playing ? "start" : "pause", fraction)
    }

    func stop(fraction: Double) {
        guard lastPlaying != nil else { return }
        lastPlaying = nil
        send("stop", fraction)
    }

    private func send(_ action: String, _ fraction: Double) {
        let r = request
        Task { await TraktService.shared.scrobble(action, request: r, progress: fraction * 100) }
    }
}
