import SwiftUI

/// Which player plays a stream.
enum PlayerMode: String, CaseIterable, Identifiable {
    /// Apple's player for MP4/HLS (AirPlay, picture-in-picture), VLC for everything else.
    case auto = "Auto"
    case vlc = "VLC"
    case apple = "Apple"
    var id: String { rawValue }
}

/// The app's highlight colour (progress bars, buttons, back button…).
enum AccentChoice: String, CaseIterable, Identifiable {
    case red = "Red", neon = "Neon purple", blue = "Blue", cyan = "Cyan", pink = "Pink", orange = "Orange", green = "Green"
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: return Color(red: 0.94, green: 0.20, blue: 0.21)
        case .neon: return Color(red: 0.70, green: 0.32, blue: 1.0)
        case .blue: return Color(red: 0.25, green: 0.55, blue: 1.0)
        case .cyan: return Color(red: 0.10, green: 0.80, blue: 0.95)
        case .pink: return Color(red: 1.0, green: 0.30, blue: 0.70)
        case .orange: return Color(red: 1.0, green: 0.58, blue: 0.10)
        case .green: return Color(red: 0.20, green: 0.80, blue: 0.40)
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark = "Dark", light = "Light", system = "Follow iPhone"
    var id: String { rawValue }

    var scheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

extension Color {
    /// The accent colour picked in Settings → Appearance.
    @MainActor static var reel: Color { AppSettings.shared.accent.color }
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
    @Published var accent: AccentChoice { didSet { d.set(accent.rawValue, forKey: "accent") } }
    @Published var appearance: AppearanceMode { didSet { d.set(appearance.rawValue, forKey: "appearance") } }
    /// Keep the sound playing when Reel goes to the background or the screen locks.
    @Published var backgroundAudio: Bool { didSet { d.set(backgroundAudio, forKey: "backgroundAudio") } }
    /// Remove a download once it has been watched to the end.
    @Published var deleteWatchedDownloads: Bool { didSet { d.set(deleteWatchedDownloads, forKey: "deleteWatchedDownloads") } }
    /// Security-scoped bookmark of a folder picked in Files; nil = Reel's own Downloads folder.
    @Published var downloadFolderBookmark: Data? { didSet { d.set(downloadFolderBookmark, forKey: "downloadFolderBookmark") } }

    private init() {
        playerMode = PlayerMode(rawValue: d.string(forKey: "playerMode") ?? "") ?? .auto
        autoPlayNext = d.object(forKey: "autoPlayNext") as? Bool ?? true
        skipIntroSeconds = d.object(forKey: "skipIntroSeconds") as? Int ?? 85
        streamSort = StreamSort(rawValue: d.string(forKey: "streamSort") ?? "") ?? .addon
        preferredAddon = d.string(forKey: "preferredAddon")
        accent = AccentChoice(rawValue: d.string(forKey: "accent") ?? "") ?? .red
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .dark
        backgroundAudio = d.object(forKey: "backgroundAudio") as? Bool ?? true
        deleteWatchedDownloads = d.bool(forKey: "deleteWatchedDownloads")
        downloadFolderBookmark = d.data(forKey: "downloadFolderBookmark")
    }
}
