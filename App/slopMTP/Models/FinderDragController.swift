import AppKit
import UniformTypeIdentifiers

/// Drags device content to Finder using file promises: the drag starts instantly, and only when
/// it's dropped does Finder say where the file should go, so it's downloaded straight there.
@MainActor
final class FinderDragController: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
    struct Promise {
        var fileName: String
        var type: UTType
        var totalBytes: UInt64
        /// Produces the file or folder at the given URL, reporting into the given progress.
        var write: @MainActor @Sendable (URL, Progress) async throws -> Void
    }

    private(set) var isDragging = false
    nonisolated private let writeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "slopMTP file promises"
        return queue
    }()

    /// Must be called while handling a mouse-dragged event (e.g. from a SwiftUI drag gesture).
    func begin(_ promises: [Promise]) {
        guard !isDragging, !promises.isEmpty,
              let event = NSApp.currentEvent, event.type == .leftMouseDragged,
              let view = event.window?.contentView
        else { return }

        let location = view.convert(event.locationInWindow, from: nil)
        let items = promises.enumerated().map { index, promise in
            let provider = NSFilePromiseProvider(fileType: promise.type.identifier, delegate: self)
            provider.userInfo = PromiseBox(promise)
            let item = NSDraggingItem(pasteboardWriter: provider)
            let icon = NSWorkspace.shared.icon(for: promise.type)
            let offset = CGFloat(min(index, 4)) * 8
            item.setDraggingFrame(NSRect(x: location.x - 32 + offset, y: location.y - 32 - offset, width: 64, height: 64), contents: icon)
            return item
        }
        isDragging = true
        view.beginDraggingSession(with: items, event: event, source: self)
    }

    // MARK: NSDraggingSource

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { isDragging = false }
    }

    // MARK: NSFilePromiseProviderDelegate

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? PromiseBox)?.promise.fileName ?? "Untitled"
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let box = filePromiseProvider.userInfo as? PromiseBox else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        // The download runs on the main actor's queue and the session's own executor; this
        // background thread just reports back when it's done.
        let reply = ReplyBox(completionHandler)
        Task { @MainActor in
            // A published file progress makes Finder draw a progress bar on the item, like its own copies.
            let progress = Progress(totalUnitCount: Int64(clamping: max(box.promise.totalBytes, 1)))
            progress.kind = .file
            progress.fileOperationKind = .downloading
            progress.fileURL = url
            progress.publish()
            defer { progress.unpublish() }
            do {
                try await box.promise.write(url, progress)
                reply.handler(nil)
            } catch {
                reply.handler(error)
            }
        }
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        writeQueue
    }
}

private final class PromiseBox: @unchecked Sendable {
    let promise: FinderDragController.Promise
    init(_ promise: FinderDragController.Promise) { self.promise = promise }
}

private final class ReplyBox: @unchecked Sendable {
    let handler: (Error?) -> Void
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
}
