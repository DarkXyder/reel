import Foundation

// Models for the Stremio add-on protocol:
// https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/responses/
// Add-ons are written by many people, so every field that isn't essential is optional and
// numbers-or-strings are decoded leniently.

/// Decodes a JSON string or number as a String ("7.8" and 7.8 both work).
struct LenientString: Codable, Hashable {
    let value: String

    init(_ value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else { value = "" }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

struct Manifest: Codable, Hashable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let logo: String?
    let types: [String]?
    let idPrefixes: [String]?
    let catalogs: [CatalogDef]?
    let resources: [ResourceRef]?
}

struct CatalogDef: Codable, Hashable, Identifiable {
    let type: String
    let id: String
    let name: String?
    let extra: [CatalogExtra]?
    let extraRequired: [String]?
    let extraSupported: [String]?

    var identity: String { "\(type)/\(id)" }

    /// Catalogs that need e.g. a search query can't be shown as a plain row.
    var hasRequiredExtra: Bool {
        if let r = extraRequired, !r.isEmpty { return true }
        return extra?.contains { $0.isRequired == true } ?? false
    }

    /// Genre choices the add-on offers for this catalog.
    var genres: [String] {
        extra?.first(where: { $0.name == "genre" })?.options ?? []
    }

    var supportsSearch: Bool {
        if extra?.contains(where: { $0.name == "search" }) == true { return true }
        return extraSupported?.contains("search") == true || extraRequired?.contains("search") == true
    }

    /// True if the catalog needs something other than search (genre, etc.): skip in search too.
    var needsNonSearchExtra: Bool {
        let required = (extra?.filter { $0.isRequired == true }.map(\.name) ?? []) + (extraRequired ?? [])
        return required.contains { $0 != "search" }
    }
}

struct CatalogExtra: Codable, Hashable {
    let name: String
    let isRequired: Bool?
    let options: [String]?
}

/// A resource is either "stream" or { "name": "stream", "types": [...], "idPrefixes": [...] }.
struct ResourceRef: Codable, Hashable {
    let name: String
    let types: [String]?
    let idPrefixes: [String]?

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            name = s; types = nil; idPrefixes = nil
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        types = try? c.decodeIfPresent([String].self, forKey: .types)
        idPrefixes = try? c.decodeIfPresent([String].self, forKey: .idPrefixes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(types, forKey: .types)
        try c.encodeIfPresent(idPrefixes, forKey: .idPrefixes)
    }

    enum Keys: String, CodingKey { case name, types, idPrefixes }
}

extension Manifest {
    /// Whether this add-on answers `resource` requests for this type and id.
    func supports(_ resource: String, type: String, id: String) -> Bool {
        guard let ref = resources?.first(where: { $0.name == resource }) else { return false }
        let types = ref.types ?? self.types ?? []
        guard types.contains(type) else { return false }
        guard let prefixes = ref.idPrefixes ?? idPrefixes, !prefixes.isEmpty else { return true }
        return prefixes.contains { id.hasPrefix($0) }
    }
}

struct MetaPreview: Codable, Hashable, Identifiable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let posterShape: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: LenientString?
    let imdbRating: LenientString?
}

struct CatalogResponse: Codable {
    let metas: [MetaPreview]
}

struct MetaDetail: Codable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: LenientString?
    let runtime: String?
    let genres: [String]?
    let imdbRating: LenientString?
    let videos: [Video]?

    var preview: MetaPreview {
        MetaPreview(id: id, type: type, name: name, poster: poster, posterShape: nil,
                    background: background, logo: logo, description: description,
                    releaseInfo: releaseInfo, imdbRating: imdbRating)
    }
}

struct MetaResponse: Codable {
    let meta: MetaDetail
}

struct Video: Codable, Hashable, Identifiable {
    let id: String
    let title: String?
    let name: String?
    let season: Int?
    let episode: Int?
    let number: Int?
    let released: String?
    let thumbnail: String?
    let overview: String?
    let description: String?

    var displayTitle: String { title ?? name ?? "Episode \(episode ?? number ?? 0)" }
    var episodeNumber: Int { episode ?? number ?? 0 }
    var summary: String? { overview ?? description }
}

struct StreamItem: Codable, Hashable {
    let url: String?
    let ytId: String?
    let infoHash: String?
    let fileIdx: Int?
    let externalUrl: String?
    let name: String?
    let title: String?
    let description: String?
    let subtitles: [Subtitle]?
    let behaviorHints: StreamHints?

    /// Add-ons put the quality in `name` and file details in `title` / `description`.
    var heading: String { name ?? "Stream" }
    var details: String { title ?? description ?? behaviorHints?.filename ?? "" }
}

struct StreamHints: Codable, Hashable {
    let notWebReady: Bool?
    let bingeGroup: String?
    let filename: String?
    let videoSize: Int?
    let proxyHeaders: ProxyHeaders?
}

struct ProxyHeaders: Codable, Hashable {
    let request: [String: String]?
}

struct StreamResponse: Codable {
    let streams: [StreamItem]
}

struct Subtitle: Codable, Hashable, Identifiable {
    let id: String?
    let url: String
    let lang: String

    var identity: String { id ?? url }
}

extension Subtitle {
    var stableID: String { identity }
}

struct SubtitlesResponse: Codable {
    let subtitles: [Subtitle]
}

/// An installed add-on: where it lives and what it said about itself.
struct InstalledAddon: Codable, Hashable, Identifiable {
    let transportUrl: String
    let manifest: Manifest

    var id: String { transportUrl }

    /// "https://host/path/manifest.json" -> "https://host/path"
    var baseURL: String {
        var s = transportUrl
        if s.hasSuffix("/manifest.json") { s.removeLast("/manifest.json".count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
