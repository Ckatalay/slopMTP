import AppKit
import Foundation
import Observation

/// Game names and artwork from the public community title database
/// (github.com/blawar/titledb), cached locally as a compact index.
@MainActor
@Observable
final class TitleDatabase {
    static let shared = TitleDatabase()
    static let onlineLookupsKey = "fetchGameArtwork"

    struct Entry: Codable, Sendable {
        var name: String
        var iconUrl: String?
        var bannerUrl: String?
        var publisher: String?
        var releaseDate: Int?
    }

    enum State: Equatable {
        case idle
        case downloading
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private var entries: [String: Entry] = [:]

    private static let sourceURL = URL(string: "https://raw.githubusercontent.com/blawar/titledb/master/US.en.json")!
    private static let maxAge: TimeInterval = 30 * 24 * 3600

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.onlineLookupsKey) as? Bool ?? true
    }

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("slopMTP", isDirectory: true).appendingPathComponent("titles.json")
    }

    func entry(for id: TitleID) -> Entry? {
        entries[id.applicationID.description]
    }

    /// Icon URL: the database's eShop icon, or tinfoil.media's per-title icon endpoint as a fallback.
    func iconURL(for id: TitleID) -> URL? {
        guard isEnabled else { return nil }
        if let icon = entry(for: id)?.iconUrl, let url = URL(string: icon) { return url }
        return URL(string: "https://tinfoil.media/ti/\(id.applicationID)/256/256/")
    }

    func loadIfNeeded() async {
        guard isEnabled, state == .idle || isFailed else { return }

        let cache = Self.cacheURL
        if let attributes = try? FileManager.default.attributesOfItem(atPath: cache.path),
           let modified = attributes[.modificationDate] as? Date {
            if let cached = await Task.detached(operation: { Self.readCache(cache) }).value {
                entries = cached
                state = .ready
                if Date().timeIntervalSince(modified) < Self.maxAge { return }
            }
        }

        if entries.isEmpty { state = .downloading }
        do {
            let (file, response) = try await URLSession.shared.download(from: Self.sourceURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let index = try await Task.detached(priority: .utility) {
                defer { try? FileManager.default.removeItem(at: file) }
                return try Self.buildIndex(from: file, writingTo: cache)
            }.value
            entries = index
            state = .ready
        } catch {
            if entries.isEmpty { state = .failed(error.localizedDescription) }
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - Index building (off the main actor)

    private struct RawEntry: Decodable {
        var id: String?
        var name: String?
        var iconUrl: String?
        var bannerUrl: String?
        var publisher: String?
        var releaseDate: Int?
    }

    nonisolated private static func buildIndex(from file: URL, writingTo cache: URL) throws -> [String: Entry] {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let raw = try JSONDecoder().decode([String: RawEntry].self, from: data)
        var index: [String: Entry] = [:]
        for entry in raw.values {
            guard let idString = entry.id, let id = TitleID(hex: idString), id.kind == .application,
                  let name = entry.name, !name.isEmpty
            else { continue }
            let key = id.description
            // Prefer entries that have artwork when the same title appears more than once.
            if let existing = index[key], existing.iconUrl != nil, entry.iconUrl == nil { continue }
            index[key] = Entry(name: name, iconUrl: entry.iconUrl, bannerUrl: entry.bannerUrl, publisher: entry.publisher, releaseDate: entry.releaseDate)
        }
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: cache, options: .atomic)
        return index
    }

    nonisolated private static func readCache(_ url: URL) -> [String: Entry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: Entry].self, from: data)
    }
}

/// Memory + disk cache for cover art.
actor CoverArtCache {
    static let shared = CoverArtCache()

    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("slopMTP/CoverArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func image(for url: URL, key: String) async -> NSImage? {
        if let cached = memory.object(forKey: key as NSString) { return cached }
        let file = directory.appendingPathComponent("\(key).jpg")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        if let task = inFlight[url] { return await task.value }

        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data)
            else { return nil }
            try? data.write(to: file, options: .atomic)
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }
}
