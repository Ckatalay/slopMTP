import Foundation
import MTPKit
import Observation

/// The special storages DBI's MTP responder exposes.
struct DBILayout: Equatable {
    var installedGames: MTPStorage
    var sdInstall: MTPStorage?
    var nandInstall: MTPStorage?
    var saves: MTPStorage?
    var album: MTPStorage?

    /// DBI names its storages "N: Description".
    init?(storages: [MTPStorage]) {
        func find(_ name: String) -> MTPStorage? {
            storages.first { DBILayout.baseName($0.info.displayName).caseInsensitiveCompare(name) == .orderedSame }
        }
        guard let installed = find("Installed games"), find("SD Card install") != nil || find("NAND install") != nil else { return nil }
        installedGames = installed
        sdInstall = find("SD Card install")
        nandInstall = find("NAND install")
        saves = find("Saves")
        album = find("Album")
    }

    static func baseName(_ name: String) -> String {
        guard let colon = name.firstIndex(of: ":"), name[..<colon].allSatisfy(\.isNumber) else { return name }
        return name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    enum InstallTarget: String, CaseIterable, Identifiable {
        case sdCard, nand
        var id: String { rawValue }
        var label: String { self == .sdCard ? "SD Card" : "System Memory" }
    }

    func storage(for target: InstallTarget) -> MTPStorage? {
        target == .sdCard ? sdInstall : nandInstall
    }
}

/// An installed game as reported by DBI, with its base / update / DLC contents.
struct InstalledGame: Identifiable, Hashable {
    struct Content: Identifiable, Hashable {
        var id: UInt32 { object.handle }
        var object: MTPObject
        var info: SwitchFileInfo

        var titleID: TitleID? { info.titleID }
        var kind: TitleID.Kind { info.kind ?? .application }
    }

    var id: String
    /// Name as shown on the console.
    var name: String
    var applicationID: TitleID?
    var folder: MTPObject?
    /// DBI's merged dump of base + update + DLC, if offered.
    var mergedDump: MTPObject?
    var contents: [Content] = []
    var summary: SwitchFileInfo.DBISummary?
    var contentsLoaded = false

    var hasBase: Bool {
        contents.contains { $0.kind == .application } || summary?.hasBase == true
    }

    var updateVersion: UInt32? {
        contents.filter { $0.kind == .update }.compactMap(\.info.version).max() ?? summary?.updateVersion
    }

    var dlcIDs: Set<TitleID> {
        Set(contents.filter { $0.kind == .addOn }.compactMap(\.titleID))
    }

    var dlcCount: Int {
        contentsLoaded ? contents.filter { $0.kind == .addOn }.count : summary?.dlcCount ?? 0
    }

    var totalSize: UInt64 {
        if contentsLoaded, !contents.isEmpty { return contents.reduce(0) { $0 + $1.object.size } }
        return mergedDump?.size ?? 0
    }
}

@MainActor
@Observable
final class SwitchLibrary {
    private(set) var games: [InstalledGame] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var syntheticHandle: UInt32 = .max
    /// Handles at or above this are placeholders for recorded installs, not device objects.
    private let syntheticFloor: UInt32 = .max - 100_000
    @ObservationIgnored private var recordedInstalls: [InstallCandidate] = []

    func game(for id: TitleID) -> InstalledGame? {
        games.first { $0.applicationID == id.applicationID }
    }

    func game(named title: String) -> InstalledGame? {
        let key = SwitchFileInfo.normalize(title)
        guard !key.isEmpty else { return nil }
        return games.first { SwitchFileInfo.normalize($0.name) == key }
    }

    /// Adds a just-installed item without asking the device, which won't list it until its next
    /// session. The next reload replaces this with what the console actually reports.
    func recordInstall(_ candidate: InstallCandidate) {
        recordedInstalls.append(candidate)
        apply(candidate)
    }

    /// Whether the console's own listing already includes this install.
    private func isReported(_ candidate: InstallCandidate) -> Bool {
        guard let id = candidate.titleID, let game = game(for: id) else { return false }
        return game.contents.contains { content in
            content.object.handle < syntheticFloor && content.titleID == id
                && (candidate.kind != .update || (content.info.version ?? 0) >= candidate.version)
        }
    }

    private func apply(_ candidate: InstallCandidate) {
        syntheticHandle &-= 1
        var info = candidate.info
        info.titleID = candidate.titleID ?? info.titleID
        info.version = candidate.version
        if info.titleID == nil { info.taggedKind = candidate.kind }
        let object = MTPObject(
            handle: syntheticHandle, storageID: 0, parent: 0, name: candidate.url.lastPathComponent,
            format: .undefined, size: candidate.size, modified: Date()
        )
        let content = InstalledGame.Content(object: object, info: info)

        let index = candidate.applicationID.flatMap { app in games.firstIndex { $0.applicationID == app } }
            ?? games.firstIndex { SwitchFileInfo.normalize($0.name) == SwitchFileInfo.normalize(candidate.info.title) }
        if let index {
            // A newer update replaces the old one; everything else is added alongside.
            if candidate.kind == .update {
                games[index].contents.removeAll { $0.kind == .update }
            }
            games[index].contents.removeAll { $0.titleID != nil && $0.titleID == content.titleID && $0.kind != .update }
            games[index].contents.append(content)
            games[index].contents.sort { ($0.kind, $0.object.name) < ($1.kind, $1.object.name) }
            games[index].contentsLoaded = true
            if candidate.kind == .application { games[index].summary?.hasBase = true }
        } else {
            var game = InstalledGame(id: "installed-\(candidate.applicationID?.description ?? candidate.info.title)", name: candidate.info.title)
            game.applicationID = candidate.applicationID
            game.contents = [content]
            game.contentsLoaded = true
            games.append(game)
            games.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func reload(session: MTPSession, layout: DBILayout) async {
        generation += 1
        let current = generation
        isLoading = true
        lastError = nil
        defer { if current == generation { isLoading = false } }

        let storageID = layout.installedGames.id
        let root: [MTPObject]
        do {
            root = try await session.contents(storageID: storageID)
        } catch {
            lastError = error.localizedDescription
            return
        }
        guard current == generation else { return }

        // Group the root listing: one folder per game plus DBI's merged dumps next to them.
        var byKey: [String: InstalledGame] = [:]
        var order: [String] = []
        func upsert(_ key: String, _ update: (inout InstalledGame) -> Void, name: String) {
            if byKey[key] == nil {
                byKey[key] = InstalledGame(id: key, name: name)
                order.append(key)
            }
            update(&byKey[key]!)
        }

        for object in root {
            let info = SwitchFileInfo(fileName: object.name)
            let key = SwitchFileInfo.normalize(object.isFolder ? object.name : info.title)
            let name = object.isFolder ? object.name : info.title
            if object.isFolder {
                upsert(key, { $0.folder = object }, name: name)
            } else if info.isInstallable {
                upsert(key, { game in
                    if info.summary != nil || game.mergedDump == nil {
                        game.mergedDump = object
                        game.summary = info.summary ?? game.summary
                    }
                    if let id = info.titleID { game.applicationID = id.applicationID }
                }, name: name)
            }
        }

        games = order.compactMap { byKey[$0] }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // Fill in per-content details (title IDs, update versions, DLC) folder by folder.
        for game in games where game.folder != nil {
            guard current == generation, let folder = game.folder else { return }
            guard let children = try? await session.contents(storageID: storageID, parent: folder.handle) else { continue }
            let contents = children
                .filter { !$0.isFolder }
                .map { InstalledGame.Content(object: $0, info: SwitchFileInfo(fileName: $0.name)) }
                .filter { $0.info.isInstallable }
                .sorted { ($0.kind, $0.object.name) < ($1.kind, $1.object.name) }
            guard current == generation, let index = games.firstIndex(where: { $0.id == game.id }) else { return }
            games[index].contents = contents
            games[index].contentsLoaded = true
            if games[index].applicationID == nil {
                games[index].applicationID = contents.compactMap(\.titleID).first?.applicationID
            }
        }
        guard current == generation else { return }
        games = Self.mergingDuplicates(games)

        // Keep showing installs the console hasn't started reporting yet.
        let pending = recordedInstalls
        recordedInstalls = pending.filter { !isReported($0) }
        recordedInstalls.forEach(apply)
    }

    /// Folds entries with the same application ID into one (e.g. an update installed before
    /// its base game can be listed under a different folder name).
    static func mergingDuplicates(_ games: [InstalledGame]) -> [InstalledGame] {
        var result: [InstalledGame] = []
        var indexByApp: [TitleID: Int] = [:]
        for game in games {
            guard let app = game.applicationID else {
                result.append(game)
                continue
            }
            guard let existingIndex = indexByApp[app] else {
                indexByApp[app] = result.count
                result.append(game)
                continue
            }
            var merged = result[existingIndex]
            let other = game
            if other.hasBase && !merged.hasBase {
                merged.name = other.name
                merged.folder = other.folder ?? merged.folder
            }
            let known = Set(merged.contents.map(\.id))
            merged.contents += other.contents.filter { !known.contains($0.id) }
            merged.contents.sort { ($0.kind, $0.object.name) < ($1.kind, $1.object.name) }
            merged.contentsLoaded = merged.contentsLoaded || other.contentsLoaded
            if merged.mergedDump == nil || (other.summary?.hasBase == true && merged.summary?.hasBase != true) {
                merged.mergedDump = other.mergedDump ?? merged.mergedDump
                merged.summary = other.summary ?? merged.summary
            }
            result[existingIndex] = merged
        }
        return result
    }
}
