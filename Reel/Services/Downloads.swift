import Foundation
import UIKit

/// One download: what it is (so it keeps its title, poster and watch progress) and where it is.
struct DownloadRecord: Codable, Identifiable, Hashable {
    enum State: String, Codable { case downloading, done, failed }

    let id: String
    let meta: MetaPreview
    let type: String
    let videoId: String
    let videoTitle: String?
    let remoteURL: String
    let fileExtension: String
    var state: State
    var received: Int64
    var total: Int64
    let created: Date
    var error: String?

    var fileName: String { "\(id).\(fileExtension)" }
    var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
    var displayTitle: String { videoTitle.map { "\(meta.name) · \($0)" } ?? meta.name }
}

/// Background downloads into Documents/Downloads (visible in the Files app).
/// They continue while Reel is in the background; iOS relaunches the app to finish them.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    static let sessionId = "com.reelplayer.app.downloads"

    @Published private(set) var records: [DownloadRecord] = []
    var backgroundCompletion: (() -> Void)?

    private var session: URLSession!
    private let delegate = DownloadDelegate()
    private var lastPublish: [String: Date] = [:]

    static let folder: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let indexURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            records = saved
        }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        // Anything marked "downloading" whose task no longer exists was lost (e.g. app deleted mid-way).
        session.getAllTasks { tasks in
            let live = Set(tasks.compactMap { $0.taskDescription })
            Task { @MainActor in
                for i in DownloadManager.shared.records.indices
                where DownloadManager.shared.records[i].state == .downloading && !live.contains(DownloadManager.shared.records[i].id) {
                    DownloadManager.shared.records[i].state = .failed
                    DownloadManager.shared.records[i].error = "Interrupted"
                }
                DownloadManager.shared.save()
            }
        }
    }

    func localURL(_ r: DownloadRecord) -> URL { Self.folder.appendingPathComponent(r.fileName) }

    func record(forVideo videoId: String) -> DownloadRecord? {
        records.first { $0.videoId == videoId && $0.state == .done }
    }

    func start(url: URL, meta: MetaPreview, type: String, videoId: String, videoTitle: String?, fileExtension: String?) {
        if records.contains(where: { $0.remoteURL == url.absoluteString && $0.state != .failed }) { return }
        let ext = (fileExtension?.isEmpty == false ? fileExtension! : (url.pathExtension.isEmpty ? "mkv" : url.pathExtension)).lowercased()
        let r = DownloadRecord(id: UUID().uuidString, meta: meta, type: type, videoId: videoId, videoTitle: videoTitle,
                               remoteURL: url.absoluteString, fileExtension: ext, state: .downloading,
                               received: 0, total: 0, created: Date(), error: nil)
        records.insert(r, at: 0)
        save()
        let task = session.downloadTask(with: url)
        task.taskDescription = r.id
        task.resume()
    }

    func retry(_ r: DownloadRecord) {
        guard let url = URL(string: r.remoteURL) else { return }
        delete(r)
        start(url: url, meta: r.meta, type: r.type, videoId: r.videoId, videoTitle: r.videoTitle, fileExtension: r.fileExtension)
    }

    func delete(_ r: DownloadRecord) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == r.id }.forEach { $0.cancel() }
        }
        try? FileManager.default.removeItem(at: localURL(r))
        records.removeAll { $0.id == r.id }
        save()
    }

    // MARK: - delegate callbacks (already on the main actor)

    func progress(id: String, received: Int64, total: Int64) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        // Publish at most a few times a second.
        let now = Date()
        if let last = lastPublish[id], now.timeIntervalSince(last) < 0.3 { return }
        lastPublish[id] = now
        records[i].received = received
        records[i].total = total
    }

    func finished(id: String, error: String?) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        if let error {
            records[i].state = .failed
            records[i].error = error
        } else {
            records[i].state = .done
            records[i].received = max(records[i].received, records[i].total)
        }
        save()
    }

    func save() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}

/// URLSession callbacks arrive on a background queue; the file is moved there (it must be done
/// before returning), everything else hops to the main actor.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in
            DownloadManager.shared.progress(id: id, received: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Task { @MainActor in DownloadManager.shared.finished(id: id, error: "HTTP \(http.statusCode)") }
            return
        }
        // Find the destination name from the saved index (extension may differ per download).
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = Self.savedExtension(id: id) ?? "mkv"
        let dest = folder.appendingPathComponent("\(id).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor in DownloadManager.shared.finished(id: id, error: nil) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in DownloadManager.shared.finished(id: id, error: message) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        let message = error.localizedDescription
        Task { @MainActor in DownloadManager.shared.finished(id: id, error: message) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            DownloadManager.shared.backgroundCompletion?()
            DownloadManager.shared.backgroundCompletion = nil
        }
    }

    private static func savedExtension(id: String) -> String? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("downloads.json")
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return nil }
        return records.first { $0.id == id }?.fileExtension
    }
}

/// Lets iOS hand finished background downloads back to the app.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            DownloadManager.shared.backgroundCompletion = completionHandler
            _ = DownloadManager.shared // recreates the session so it can deliver the events
        }
    }
}
