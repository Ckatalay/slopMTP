import Foundation
import MTPKit
import Observation

@MainActor
@Observable
final class Transfer: Identifiable {
    enum Direction { case download, upload }

    enum State: Equatable {
        case queued
        case preparing
        case running
        case completed
        case failed(String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .completed, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let name: String
    let direction: Direction
    /// Destination storage / folder for uploads, source for downloads.
    let storageID: UInt32
    let parent: UInt32
    var state: State = .queued
    var totalBytes: UInt64 = 0
    var completedBytes: UInt64 = 0 {
        didSet { externalProgress?.completedUnitCount = Int64(clamping: completedBytes) }
    }
    var currentFile: String?
    var startedAt: Date?
    var finishedAt: Date?

    /// Where a finished download was saved (the file, or the top folder).
    var resultURL: URL?
    /// Re-runs the transfer; downloads resume from their partial files.
    @ObservationIgnored var retry: (@MainActor () -> Void)?
    /// Mirrors progress into a system `Progress`, e.g. for a drag to Finder.
    @ObservationIgnored var externalProgress: Progress?
    @ObservationIgnored fileprivate var completion: (@MainActor (Transfer) -> Void)?
    @ObservationIgnored fileprivate var task: Task<Void, Never>?
    @ObservationIgnored fileprivate let work: @MainActor (MTPSession, Transfer, ProgressRelay) async throws -> Void

    fileprivate init(
        name: String, direction: Direction, storageID: UInt32, parent: UInt32,
        work: @escaping @MainActor (MTPSession, Transfer, ProgressRelay) async throws -> Void
    ) {
        self.name = name
        self.direction = direction
        self.storageID = storageID
        self.parent = parent
        self.work = work
    }

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }

    /// Average throughput in bytes per second.
    var bytesPerSecond: Double? {
        guard let startedAt else { return nil }
        let elapsed = (finishedAt ?? Date()).timeIntervalSince(startedAt)
        guard elapsed > 0.5 else { return nil }
        return Double(completedBytes) / elapsed
    }
}

/// Runs transfers one at a time (MTP only allows a single transaction at once anyway).
@MainActor
@Observable
final class TransferQueue {
    private(set) var transfers: [Transfer] = []
    @ObservationIgnored var session: MTPSession?
    @ObservationIgnored var onTransferFinished: ((Transfer) -> Void)?
    @ObservationIgnored private var isRunning = false

    var hasActiveTransfers: Bool { transfers.contains { !$0.state.isFinished } }
    var hasFinishedTransfers: Bool { transfers.contains { $0.state.isFinished } }

    func cancel(_ transfer: Transfer) {
        switch transfer.state {
        case .queued:
            transfer.state = .cancelled
        case .preparing, .running:
            transfer.task?.cancel()
        default:
            break
        }
    }

    func cancelAll() {
        transfers.forEach(cancel)
    }

    func clearFinished() {
        transfers.removeAll { $0.state.isFinished }
    }

    // MARK: - Enqueueing

    /// Downloads a file or folder. With `resuming`, existing names are reused instead of made
    /// unique: finished files are skipped and `.part` files continue where they stopped.
    @discardableResult
    func enqueueDownload(_ object: MTPObject, to directory: URL, resuming: Bool = false, exactURL: URL? = nil) -> Transfer {
        let transfer = Transfer(name: object.name, direction: .download, storageID: object.storageID, parent: object.parent) { session, transfer, relay in
            transfer.state = .preparing
            var plan: [(MTPObject, URL)] = []
            let root = try await Self.planDownload(object, into: directory, reuseExisting: resuming, exactURL: exactURL, session: session, plan: &plan)
            transfer.resultURL = root
            let alreadyDone = resuming ? Self.completedSize(of: object, at: root, plan: plan) : 0
            transfer.totalBytes = plan.reduce(alreadyDone) { $0 + $1.0.size }
            transfer.completedBytes = alreadyDone
            transfer.state = .running

            var finishedBytes = alreadyDone
            for (file, url) in plan {
                try Task.checkCancellation()
                transfer.currentFile = file.name
                try await session.download(file, to: url, progress: relay.handler(offset: finishedBytes))
                finishedBytes += file.size
                transfer.completedBytes = finishedBytes
            }
            transfer.currentFile = root.lastPathComponent
        }
        transfer.retry = { [weak self] in self?.enqueueDownload(object, to: directory, resuming: true, exactURL: exactURL) }
        append(transfer)
        return transfer
    }

    /// Downloads and waits for the result, e.g. to hand a file to Finder.
    func downloadAndWait(_ object: MTPObject, to directory: URL, exactURL: URL? = nil, progress: Progress? = nil) async throws -> URL {
        let transfer = enqueueDownload(object, to: directory, exactURL: exactURL)
        transfer.externalProgress = progress
        return try await withCheckedThrowingContinuation { continuation in
            transfer.completion = { transfer in
                switch transfer.state {
                case .completed:
                    if let url = transfer.resultURL {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: MTPError.localFile("The download produced no file."))
                    }
                case .failed(let message):
                    continuation.resume(throwing: MTPError.localFile(message))
                default:
                    continuation.resume(throwing: MTPError.cancelled)
                }
            }
        }
    }

    @discardableResult
    func enqueueUpload(_ url: URL, storageID: UInt32, parent: UInt32) -> Transfer {
        let transfer = Transfer(name: url.lastPathComponent, direction: .upload, storageID: storageID, parent: parent) { session, transfer, relay in
            transfer.state = .preparing
            let files = try Self.planUpload(url)
            transfer.totalBytes = files.reduce(0) { $0 + $1.size }
            transfer.state = .running

            var folderHandles: [String: UInt32] = ["": parent]
            var finishedBytes: UInt64 = 0
            for entry in files {
                try Task.checkCancellation()
                let parentKey = (entry.relativePath as NSString).deletingLastPathComponent
                guard let parentHandle = folderHandles[parentKey] else { continue }
                if entry.isDirectory {
                    folderHandles[entry.relativePath] = try await session.createFolder(
                        name: entry.url.lastPathComponent, storageID: storageID, parent: parentHandle
                    )
                } else {
                    transfer.currentFile = entry.url.lastPathComponent
                    try await session.upload(entry.url, storageID: storageID, parent: parentHandle, progress: relay.handler(offset: finishedBytes))
                    finishedBytes += entry.size
                    transfer.completedBytes = finishedBytes
                }
            }
        }
        transfer.retry = { [weak self] in self?.enqueueUpload(url, storageID: storageID, parent: parent) }
        append(transfer)
        return transfer
    }

    // MARK: - Running

    private func append(_ transfer: Transfer) {
        transfers.append(transfer)
        runNext()
    }

    private func runNext() {
        guard !isRunning, let session, let next = transfers.first(where: { $0.state == .queued }) else { return }
        isRunning = true
        next.startedAt = Date()
        let relay = ProgressRelay(transfer: next)
        next.task = Task {
            do {
                try await next.work(session, next, relay)
                next.completedBytes = next.totalBytes
                next.state = .completed
            } catch is CancellationError {
                next.state = .cancelled
            } catch MTPError.cancelled {
                next.state = .cancelled
            } catch {
                next.state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            next.finishedAt = Date()
            next.task = nil
            isRunning = false
            next.completion?(next)
            next.completion = nil
            onTransferFinished?(next)
            runNext()
        }
    }

    // MARK: - Planning

    private static func planDownload(
        _ object: MTPObject, into directory: URL, reuseExisting: Bool, exactURL: URL? = nil,
        session: MTPSession, plan: inout [(MTPObject, URL)]
    ) async throws -> URL {
        let name = sanitize(object.name)
        let destination = exactURL ?? (reuseExisting ? directory.appendingPathComponent(name) : uniqueURL(in: directory, name: name))
        if object.isFolder {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in try await session.contents(storageID: object.storageID, parent: object.handle) {
                try Task.checkCancellation()
                _ = try await planDownload(child, into: destination, reuseExisting: reuseExisting, session: session, plan: &plan)
            }
        } else if !(reuseExisting && isComplete(object, at: destination)) {
            plan.append((object, destination))
        }
        return destination
    }

    private static func isComplete(_ object: MTPObject, at url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
        return size == object.size
    }

    /// Bytes of `object` already on disk as finished files (for progress when resuming).
    private static func completedSize(of object: MTPObject, at root: URL, plan: [(MTPObject, URL)]) -> UInt64 {
        guard object.isFolder else { return 0 }
        let pending = Set(plan.map(\.1.path))
        var total: UInt64 = 0
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension != "part", !pending.contains(url.path),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true
            else { continue }
            total += UInt64(values.fileSize ?? 0)
        }
        return total
    }

    struct UploadEntry {
        var url: URL
        var relativePath: String
        var isDirectory: Bool
        var size: UInt64
    }

    /// Flattens a file or folder into upload entries; folders precede their contents.
    private static func planUpload(_ url: URL) throws -> [UploadEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isHiddenKey]
        let values = try url.resourceValues(forKeys: Set(keys))
        guard values.isDirectory == true else {
            return [UploadEntry(url: url, relativePath: url.lastPathComponent, isDirectory: false, size: UInt64(values.fileSize ?? 0))]
        }

        var entries = [UploadEntry(url: url, relativePath: url.lastPathComponent, isDirectory: true, size: 0)]
        let basePath = url.deletingLastPathComponent().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return entries
        }
        for case let child as URL in enumerator {
            let childValues = try child.resourceValues(forKeys: Set(keys))
            var relative = String(child.standardizedFileURL.path.dropFirst(basePath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            entries.append(UploadEntry(
                url: child, relativePath: relative,
                isDirectory: childValues.isDirectory == true,
                size: UInt64(childValues.fileSize ?? 0)
            ))
        }
        return entries
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    private static func uniqueURL(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }
}

/// Forwards progress from the session's queue to the main actor, throttled to ~10 updates/sec.
final class ProgressRelay: @unchecked Sendable {
    private weak var transfer: Transfer?
    private let lock = NSLock()
    private var lastUpdate = Date.distantPast

    init(transfer: Transfer) {
        self.transfer = transfer
    }

    func handler(offset: UInt64) -> MTPProgressHandler {
        { [self] done, _ in
            let now = Date()
            let shouldPost = lock.withLock {
                guard now.timeIntervalSince(lastUpdate) >= 0.1 else { return false }
                lastUpdate = now
                return true
            }
            guard shouldPost else { return }
            Task { @MainActor [weak transfer] in
                transfer?.completedBytes = offset + done
            }
        }
    }
}
