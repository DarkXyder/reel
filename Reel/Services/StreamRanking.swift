import Foundation

/// Resolution read from the stream's name / title / filename ("2160p", "4K", "1080p"…).
enum StreamQuality: Int, Comparable, CaseIterable, Identifiable {
    case unknown = 0, sd, hd720, hd1080, uhd

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .uhd: return "4K"
        case .hd1080: return "1080p"
        case .hd720: return "720p"
        case .sd: return "SD"
        case .unknown: return "Other"
        }
    }

    static func < (a: StreamQuality, b: StreamQuality) -> Bool { a.rawValue < b.rawValue }
}

extension StreamItem {
    private var searchText: String {
        [name, title, description, behaviorHints?.filename].compactMap { $0 }.joined(separator: " ").lowercased()
    }

    var quality: StreamQuality {
        let t = searchText
        if t.contains("2160p") || t.contains("4k") || t.contains("uhd") { return .uhd }
        if t.contains("1080p") || t.contains("1080i") || t.contains("fhd") { return .hd1080 }
        if t.contains("720p") { return .hd720 }
        if t.contains("480p") || t.contains("576p") || t.contains("360p") || t.contains(" sd") { return .sd }
        return .unknown
    }

    /// Size from behaviorHints.videoSize, or text like "💾 2.4 GB".
    var sizeBytes: Int64? {
        if let s = behaviorHints?.videoSize, s > 0 { return Int64(s) }
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(gib|gb|mib|mb)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let t = searchText
        guard let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let numR = Range(m.range(at: 1), in: t), let unitR = Range(m.range(at: 2), in: t),
              let n = Double(t[numR].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let unit = t[unitR]
        let mult: Double = unit.hasPrefix("g") ? 1_073_741_824 : 1_048_576
        return Int64(n * mult)
    }

    /// File extension from the hinted filename or the URL ("mkv", "mp4", "m3u8"…).
    var fileExtension: String? {
        if let f = behaviorHints?.filename, let ext = f.split(separator: ".").last, ext.count <= 5 {
            return ext.lowercased()
        }
        if let u = url.flatMap(URL.init(string:)), !u.pathExtension.isEmpty { return u.pathExtension.lowercased() }
        return nil
    }
}
