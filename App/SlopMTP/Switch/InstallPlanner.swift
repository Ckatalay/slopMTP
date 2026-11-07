import Foundation

/// A dropped file, classified and checked against what's already installed.
struct InstallCandidate: Identifiable, Hashable {
    enum Status: Hashable {
        /// Not installed yet.
        case new
        /// Newer than the installed update.
        case upgrade(from: UInt32)
        /// The exact content is already on the console.
        case alreadyInstalled
        /// An update that is not newer than the installed one.
        case notNewer(installed: UInt32)
        /// A newer update for the same game is in this batch.
        case superseded
        /// Update or DLC whose base game is neither installed nor in this batch.
        case missingBase
        /// No title ID could be determined; installed as-is.
        case unidentified

        var isWarning: Bool {
            switch self {
            case .missingBase, .unidentified: return true
            default: return false
            }
        }

        /// Whether the candidate is selected by default.
        var selectedByDefault: Bool {
            switch self {
            case .alreadyInstalled, .notNewer, .superseded: return false
            default: return true
            }
        }

        var message: String {
            switch self {
            case .new: return "New"
            case .upgrade(let from): return "Updates \(TitleVersion.short(from)) → newer"
            case .alreadyInstalled: return "Already installed"
            case .notNewer(let installed): return "Installed update is already \(TitleVersion.short(installed))"
            case .superseded: return "A newer update is also being installed"
            case .missingBase: return "Base game isn't installed"
            case .unidentified: return "Couldn't identify title"
            }
        }
    }

    let id = UUID()
    var url: URL
    var info: SwitchFileInfo
    var titleID: TitleID?
    var kind: TitleID.Kind
    var version: UInt32
    var size: UInt64
    var status: Status
    var isSelected: Bool

    var applicationID: TitleID? { titleID?.applicationID }
}

@MainActor
enum InstallPlanner {
    /// Expands folders, classifies every installable file and orders the batch so that, per game,
    /// the base game installs before its update, and the update before DLC.
    static func plan(_ urls: [URL], library: SwitchLibrary) -> [InstallCandidate] {
        var candidates = expand(urls).map { url -> InstallCandidate in
            let info = SwitchFileInfo(fileName: url.lastPathComponent)
            var titleID = info.titleID
            var version = info.version
            var kind = info.kind
            if titleID == nil || version == nil, let inspected = NSPInspector.inspect(url) {
                titleID = titleID ?? inspected.titleID
                version = version ?? inspected.version
                kind = kind ?? inspected.kind
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            return InstallCandidate(
                url: url, info: info, titleID: titleID,
                kind: titleID?.kind ?? kind ?? .application,
                version: version ?? 0, size: size,
                status: .new, isSelected: true
            )
        }

        let batchBases = Set(candidates.filter { $0.kind == .application }.compactMap(\.applicationID))
        let batchBaseNames = Set(candidates.filter { $0.kind == .application }.map { SwitchFileInfo.normalize($0.info.title) })
        var newestUpdate: [TitleID: UInt32] = [:]
        for candidate in candidates where candidate.kind == .update {
            if let app = candidate.applicationID {
                newestUpdate[app] = max(newestUpdate[app] ?? 0, candidate.version)
            }
        }

        for index in candidates.indices {
            let candidate = candidates[index]
            let installed = candidate.applicationID.flatMap(library.game(for:)) ?? library.game(named: candidate.info.title)
            let baseAvailable = installed?.hasBase == true
                || candidate.applicationID.map(batchBases.contains) == true
                || batchBaseNames.contains(SwitchFileInfo.normalize(candidate.info.title))

            let status: InstallCandidate.Status
            switch candidate.kind {
            case _ where candidate.titleID == nil && candidate.info.summary == nil && installed == nil:
                status = .unidentified
            case .application:
                status = installed?.hasBase == true ? .alreadyInstalled : .new
            case .update:
                if let app = candidate.applicationID, let newest = newestUpdate[app], newest > candidate.version {
                    status = .superseded
                } else if let current = installed?.updateVersion {
                    status = candidate.version > current ? .upgrade(from: current) : .notNewer(installed: current)
                } else {
                    status = baseAvailable ? .new : .missingBase
                }
            case .addOn:
                if let id = candidate.titleID, installed?.dlcIDs.contains(id) == true {
                    status = .alreadyInstalled
                } else {
                    status = baseAvailable ? .new : .missingBase
                }
            }
            candidates[index].status = status
            candidates[index].isSelected = status.selectedByDefault
        }

        return candidates.sorted { lhs, rhs in
            let lhsGame = lhs.applicationID?.description ?? SwitchFileInfo.normalize(lhs.info.title)
            let rhsGame = rhs.applicationID?.description ?? SwitchFileInfo.normalize(rhs.info.title)
            if lhs.kind != rhs.kind {
                // Bases first across the whole batch, then updates, then DLC.
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            if lhsGame != rhsGame { return lhs.info.title.localizedStandardCompare(rhs.info.title) == .orderedAscending }
            return lhs.version < rhs.version
        }
    }

    private static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let child = enumerator?.nextObject() as? URL {
                    if SwitchFileInfo.installableExtensions.contains(child.pathExtension.lowercased()) {
                        result.append(child)
                    }
                }
            } else if SwitchFileInfo.installableExtensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
    }
}
