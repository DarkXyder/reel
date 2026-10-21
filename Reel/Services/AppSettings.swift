import Foundation

/// Which player plays a stream.
enum PlayerMode: String, CaseIterable, Identifiable {
    /// Apple's player for MP4/HLS (AirPlay, picture-in-picture), VLC for everything else.
    case auto = "Auto"
    case vlc = "VLC"
    case apple = "Apple"
    var id: String { rawValue }
}

/// How the streams list is ordered.
enum StreamSort: String, CaseIterable, Identifiable {
    case addon = "Add-on order"
    case quality = "Best quality"
    case largest = "Largest"
    case smallest = "Smallest"
    var id: String { rawValue }
}

/// App-wide preferences, saved in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var playerMode: PlayerMode { didSet { d.set(playerMode.rawValue, forKey: "playerMode") } }
    @Published var autoPlayNext: Bool { didSet { d.set(autoPlayNext, forKey: "autoPlayNext") } }
    /// How far "Skip intro" jumps; 0 hides the button.
    @Published var skipIntroSeconds: Int { didSet { d.set(skipIntroSeconds, forKey: "skipIntroSeconds") } }
    @Published var streamSort: StreamSort { didSet { d.set(streamSort.rawValue, forKey: "streamSort") } }
    /// Add-on whose streams are listed first (transport URL).
    @Published var preferredAddon: String? { didSet { d.set(preferredAddon, forKey: "preferredAddon") } }

    private init() {
        playerMode = PlayerMode(rawValue: d.string(forKey: "playerMode") ?? "") ?? .auto
        autoPlayNext = d.object(forKey: "autoPlayNext") as? Bool ?? true
        skipIntroSeconds = d.object(forKey: "skipIntroSeconds") as? Int ?? 85
        streamSort = StreamSort(rawValue: d.string(forKey: "streamSort") ?? "") ?? .addon
        preferredAddon = d.string(forKey: "preferredAddon")
    }
}
