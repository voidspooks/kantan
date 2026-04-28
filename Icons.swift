import AppKit

// MARK: - Icon cache (devicon SVGs)

/// Lazy-fetches devicon SVGs from jsDelivr's CDN, caches in memory and on disk.
/// Disk cache lives in `~/Library/Application Support/Kantan/icons/`.
/// First sighting of a language hits the network; everything after is local.
/// Failed fetches are remembered for the session so a 404 doesn't loop.
final class IconCache {
    static let shared = IconCache()

    private static let baseURL = URL(string: "https://cdn.jsdelivr.net/gh/devicons/devicon/icons/")!
    private static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Kantan/icons")
    }()

    private var memory: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private var inFlight: [String: [() -> Void]] = [:]

    private init() {
        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
    }

    /// Returns a cached image immediately if available. Otherwise schedules an async
    /// fetch and calls `onLoad` (on the main thread) once the image lands. Returns
    /// nil and skips the callback if the path has already failed in this session.
    func image(forPath path: String, onLoad: @escaping () -> Void) -> NSImage? {
        if let cached = memory[path] { return cached }
        if failed.contains(path)     { return nil }

        let diskURL = Self.cacheDirectory.appendingPathComponent(diskFilename(for: path))
        if FileManager.default.fileExists(atPath: diskURL.path),
           let image = NSImage(contentsOf: diskURL) {
            memory[path] = image
            return image
        }

        if inFlight[path] != nil {
            inFlight[path]?.append(onLoad)
            return nil
        }
        inFlight[path] = [onLoad]

        let remoteURL = Self.baseURL.appendingPathComponent("\(path).svg")
        URLSession.shared.dataTask(with: remoteURL) { [weak self] data, response, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let callbacks = self.inFlight.removeValue(forKey: path) ?? []
                guard let data = data,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let image = NSImage(data: data) else {
                    self.failed.insert(path)
                    return
                }
                try? data.write(to: diskURL)
                self.memory[path] = image
                callbacks.forEach { $0() }
            }
        }.resume()

        return nil
    }

    private func diskFilename(for path: String) -> String {
        return path.replacingOccurrences(of: "/", with: "_") + ".svg"
    }
}
