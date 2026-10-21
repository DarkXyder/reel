import Foundation

enum AddonError: LocalizedError {
    case badURL(String)
    case http(Int)
    case notAnAddon

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "Not a valid add-on address: \(s)"
        case .http(let code): return "The add-on answered with HTTP \(code)."
        case .notAnAddon: return "That address didn't return a Stremio add-on manifest."
        }
    }
}

/// Talks to Stremio add-ons over HTTP: /manifest.json, /catalog, /meta, /stream, /subtitles.
struct AddonClient {
    static let shared = AddonClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        return URLSession(configuration: config)
    }()

    /// Accepts https://…/manifest.json, a base URL, or a stremio:// link.
    static func normalize(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        if !s.contains("://") { s = "https://" + s }
        if !s.hasSuffix("manifest.json") {
            while s.hasSuffix("/") { s.removeLast() }
            s += "/manifest.json"
        }
        return s
    }

    func fetchManifest(_ input: String) async throws -> InstalledAddon {
        let transport = Self.normalize(input)
        guard let url = URL(string: transport) else { throw AddonError.badURL(input) }
        do {
            let manifest: Manifest = try await get(url)
            return InstalledAddon(transportUrl: transport, manifest: manifest)
        } catch is DecodingError {
            throw AddonError.notAnAddon
        }
    }

    func catalog(_ addon: InstalledAddon, _ catalog: CatalogDef, search: String? = nil, genre: String? = nil,
                 skip: Int = 0) async throws -> [MetaPreview] {
        var extras: [(String, String)] = []
        if let genre { extras.append(("genre", genre)) }
        if let search { extras.append(("search", search)) }
        if skip > 0 { extras.append(("skip", String(skip))) }
        let response: CatalogResponse = try await get(resourceURL(addon, "catalog", catalog.type, catalog.id, extras))
        return response.metas
    }

    func meta(_ addon: InstalledAddon, type: String, id: String) async throws -> MetaDetail {
        let response: MetaResponse = try await get(resourceURL(addon, "meta", type, id, []))
        return response.meta
    }

    func streams(_ addon: InstalledAddon, type: String, videoId: String) async throws -> [StreamItem] {
        let response: StreamResponse = try await get(resourceURL(addon, "stream", type, videoId, []))
        return response.streams
    }

    func subtitles(_ addon: InstalledAddon, type: String, videoId: String) async throws -> [Subtitle] {
        let response: SubtitlesResponse = try await get(resourceURL(addon, "subtitles", type, videoId, []))
        return response.subtitles
    }

    // MARK: - plumbing

    /// {base}/{resource}/{type}/{id}[/{extra=value&…}].json, each part encoded like encodeURIComponent.
    private func resourceURL(_ addon: InstalledAddon, _ resource: String, _ type: String, _ id: String,
                             _ extras: [(String, String)]) throws -> URL {
        var path = "\(addon.baseURL)/\(resource)/\(Self.encode(type))/\(Self.encode(id))"
        if !extras.isEmpty {
            path += "/" + extras.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
        }
        path += ".json"
        guard let url = URL(string: path) else { throw AddonError.badURL(path) }
        return url
    }

    private static let componentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.!~*'()")
        return set
    }()

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? s
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AddonError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
