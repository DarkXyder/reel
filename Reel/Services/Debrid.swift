import Foundation
import Security

/// API keys live in the iOS Keychain, not in UserDefaults.
enum Keychain {
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.reelplayer.app",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.reelplayer.app",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum DebridProvider: String, CaseIterable, Identifiable, Codable {
    case realDebrid = "Real-Debrid"
    case allDebrid = "AllDebrid"

    var id: String { rawValue }

    var keyPageURL: URL {
        switch self {
        case .realDebrid: return URL(string: "https://real-debrid.com/apitoken")!
        case .allDebrid: return URL(string: "https://alldebrid.com/apikeys/")!
        }
    }
}

struct DebridAccount: Equatable {
    let username: String
    let premium: Bool
    let expires: Date?
}

/// A file in your own debrid account. `directURL` is set when it can be played as-is;
/// otherwise `link` must be unlocked first (AllDebrid saved links).
struct DebridFile: Identifiable, Hashable {
    let id: String
    let filename: String
    let size: Int64?
    let date: Date?
    let directURL: URL?
    let link: String?
}

enum DebridError: LocalizedError {
    case noKey, http(Int), api(String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your API key in Settings."
        case .http(let c): return "The debrid service answered with HTTP \(c)."
        case .api(let m): return m
        }
    }
}

/// Your debrid account: status, your downloads list, and unlocking a link you saved there.
@MainActor
final class DebridService: ObservableObject {
    @Published var provider: DebridProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "debrid.provider"); account = nil }
    }
    @Published private(set) var account: DebridAccount?
    @Published private(set) var lastError: String?

    init() {
        provider = DebridProvider(rawValue: UserDefaults.standard.string(forKey: "debrid.provider") ?? "") ?? .realDebrid
    }

    var apiKey: String? { Keychain.get(provider.rawValue) }
    var hasKey: Bool { !(apiKey ?? "").isEmpty }

    func setKey(_ key: String?) {
        Keychain.set(key?.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.rawValue)
        account = nil
        objectWillChange.send()
    }

    func refreshAccount() async {
        do {
            account = try await fetchAccount()
            lastError = nil
        } catch {
            account = nil
            lastError = error.localizedDescription
        }
    }

    func fetchAccount() async throws -> DebridAccount {
        switch provider {
        case .realDebrid:
            struct User: Decodable { let username: String; let type: String; let expiration: String? }
            let u: User = try await rd("user")
            return DebridAccount(username: u.username, premium: u.type == "premium", expires: u.expiration.flatMap(Self.iso))
        case .allDebrid:
            struct R: Decodable { let data: D?; let error: E? }
            struct D: Decodable { let user: U }
            struct U: Decodable { let username: String; let isPremium: Bool; let premiumUntil: Double? }
            struct E: Decodable { let message: String }
            let r: R = try await ad("user", [:])
            guard let u = r.data?.user else { throw DebridError.api(r.error?.message ?? "AllDebrid error") }
            return DebridAccount(username: u.username, premium: u.isPremium,
                                 expires: u.premiumUntil.map { Date(timeIntervalSince1970: $0) })
        }
    }

    func files() async throws -> [DebridFile] {
        switch provider {
        case .realDebrid:
            struct DL: Decodable {
                let id: String; let filename: String; let filesize: Int64?; let download: String
                let generated: String?; let streamable: Int?
            }
            let list: [DL] = try await rd("downloads?limit=100")
            return list.map {
                DebridFile(id: $0.id, filename: $0.filename, size: $0.filesize, date: $0.generated.flatMap(Self.iso),
                           directURL: URL(string: $0.download), link: nil)
            }
        case .allDebrid:
            struct R: Decodable { let data: D?; let error: E? }
            struct D: Decodable { let links: [L] }
            struct L: Decodable { let link: String; let filename: String; let size: Int64?; let date: Double? }
            struct E: Decodable { let message: String }
            let r: R = try await ad("user/links", [:])
            guard let links = r.data?.links else { throw DebridError.api(r.error?.message ?? "AllDebrid error") }
            return links.map {
                DebridFile(id: $0.link, filename: $0.filename, size: $0.size,
                           date: $0.date.map { Date(timeIntervalSince1970: $0) }, directURL: nil, link: $0.link)
            }
        }
    }

    /// A playable URL for a file in your account.
    func playableURL(_ file: DebridFile) async throws -> URL {
        if let url = file.directURL { return url }
        guard let link = file.link else { throw DebridError.api("Nothing to play.") }
        struct R: Decodable { let data: D?; let error: E? }
        struct D: Decodable { let link: String }
        struct E: Decodable { let message: String }
        let r: R = try await ad("link/unlock", ["link": link])
        guard let s = r.data?.link, let url = URL(string: s) else { throw DebridError.api(r.error?.message ?? "Couldn't unlock the link.") }
        return url
    }

    // MARK: - HTTP

    private func rd<T: Decodable>(_ path: String) async throws -> T {
        guard let key = apiKey, !key.isEmpty else { throw DebridError.noKey }
        var req = URLRequest(url: URL(string: "https://api.real-debrid.com/rest/1.0/" + path)!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return try await send(req)
    }

    private func ad<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T {
        guard let key = apiKey, !key.isEmpty else { throw DebridError.noKey }
        var c = URLComponents(string: "https://api.alldebrid.com/v4/" + path)!
        c.queryItems = [URLQueryItem(name: "agent", value: "reel")] + query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DebridError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func iso(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
