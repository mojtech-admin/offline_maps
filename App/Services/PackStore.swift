import Foundation

struct StateInfo: Identifiable, Hashable {
    var id: String            // file prefix, e.g. "AZ"
    var name: String
    var center: Coord
    var declination: Double   // magnetic declination in degrees, east positive (2026 values)

    static func == (a: StateInfo, b: StateInfo) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let all: [StateInfo] = [
        StateInfo(id: "AZ", name: "Arizona", center: Coord(lat: 33.4484, lon: -112.0740), declination: 9.5),
        StateInfo(id: "CA", name: "California", center: Coord(lat: 34.0522, lon: -118.2437), declination: 11.5),
        StateInfo(id: "CO", name: "Colorado", center: Coord(lat: 39.7392, lon: -104.9903), declination: 7.5),
        StateInfo(id: "LA", name: "Louisiana", center: Coord(lat: 29.9511, lon: -90.0715), declination: -1.0),
        StateInfo(id: "MA", name: "Massachusetts", center: Coord(lat: 42.3601, lon: -71.0589), declination: -14.0),
        StateInfo(id: "NV", name: "Nevada", center: Coord(lat: 36.1699, lon: -115.1398), declination: 11.0),
        StateInfo(id: "NM", name: "New Mexico", center: Coord(lat: 35.0844, lon: -106.6504), declination: 8.0),
        StateInfo(id: "TN", name: "Tennessee", center: Coord(lat: 36.1627, lon: -86.7816), declination: -4.0),
    ]
}

/// Downloads state map packs once (over Wi-Fi, before the trip) and keeps them on the phone.
/// After that the app never needs the network.
final class PackStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var progress: [String: Double] = [:]     // state id -> 0...1 while downloading
    @Published var lastError: String?

    private static let parts = ["roads", "search.sqlite"]
    private var session: URLSession!
    private var taskInfo: [Int: (state: String, part: String)] = [:]
    private var partProgress: [String: [String: Double]] = [:]
    private var remaining: [String: Int] = [:]

    /// Folder with the pack files, e.g. https://github.com/you/offroute/releases/download/maps-v1/
    /// Set at build time through Info.plist (see project.yml).
    static var baseURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "MapPackBaseURL") as? String,
              !s.isEmpty, let url = URL(string: s.hasSuffix("/") ? s : s + "/") else { return nil }
        return url
    }

    static var folder: URL {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Packs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Packs can be downloaded again, so keep them out of iCloud backups (App Review requires this).
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    static func fileURL(_ state: String, _ part: String) -> URL {
        folder.appendingPathComponent("\(state).\(part)")
    }

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = false          // packs are hundreds of megabytes
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        refresh()
    }

    func refresh() {
        installed = Set(StateInfo.all.map(\.id).filter { state in
            Self.parts.allSatisfy { FileManager.default.fileExists(atPath: Self.fileURL(state, $0).path) }
        })
    }

    func download(_ state: String) {
        guard progress[state] == nil else { return }
        guard let base = Self.baseURL else {
            lastError = "This build has no map download address configured."
            return
        }
        lastError = nil
        progress[state] = 0
        partProgress[state] = [:]
        remaining[state] = Self.parts.count
        for part in Self.parts {
            let task = session.downloadTask(with: base.appendingPathComponent("\(state).\(part)"))
            taskInfo[task.taskIdentifier] = (state, part)
            task.resume()
        }
    }

    func delete(_ state: String) {
        for part in Self.parts { try? FileManager.default.removeItem(at: Self.fileURL(state, part)) }
        refresh()
    }

    // MARK: URLSessionDownloadDelegate (delivered on the main queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let info = taskInfo[downloadTask.taskIdentifier], totalBytesExpectedToWrite > 0 else { return }
        partProgress[info.state, default: [:]][info.part] =
            Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        // the road file is by far the larger part
        let p = partProgress[info.state] ?? [:]
        progress[info.state] = 0.9 * (p["roads"] ?? 0) + 0.1 * (p["search.sqlite"] ?? 0)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let info = taskInfo[downloadTask.taskIdentifier] else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            lastError = "Download of \(info.state) failed (HTTP \(status))."
            return
        }
        let dest = Self.fileURL(info.state, info.part)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            lastError = "Could not save \(info.state): \(error.localizedDescription)"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let info = taskInfo.removeValue(forKey: task.taskIdentifier) else { return }
        if let error = error { lastError = "Download of \(info.state) failed: \(error.localizedDescription)" }
        remaining[info.state, default: 1] -= 1
        if remaining[info.state] ?? 0 <= 0 {
            progress[info.state] = nil
            partProgress[info.state] = nil
            refresh()
        }
    }
}
