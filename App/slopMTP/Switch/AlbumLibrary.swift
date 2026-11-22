import AppKit
import AVFoundation
import Foundation
import ImageIO
import MTPKit
import Observation

/// Screenshots and videos from DBI's Album storage, grouped by game folder.
@MainActor
@Observable
final class AlbumLibrary {
    struct Section: Identifiable, Hashable {
        var id: UInt32
        var name: String
        var items: [MTPObject]
    }

    private(set) var sections: [Section] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var lastError: String?

    var allItems: [MTPObject] { sections.flatMap(\.items) }

    func reload(session: MTPSession, storage: MTPStorage) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            var result: [Section] = []
            var loose: [MTPObject] = []
            for object in try await session.contents(storageID: storage.id) {
                if object.isFolder {
                    let items = try await media(in: object, session: session, depth: 2)
                    if !items.isEmpty {
                        result.append(Section(id: object.handle, name: object.name, items: items))
                    }
                } else if AlbumMedia.isMedia(object.name) {
                    loose.append(object)
                }
            }
            if !loose.isEmpty {
                result.append(Section(id: 0, name: "Other", items: AlbumMedia.newestFirst(loose)))
            }
            sections = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            hasLoaded = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Media files in a folder, looking into date subfolders up to `depth` levels.
    private func media(in folder: MTPObject, session: MTPSession, depth: Int) async throws -> [MTPObject] {
        var items: [MTPObject] = []
        for child in try await session.contents(storageID: folder.storageID, parent: folder.handle) {
            if child.isFolder, depth > 1 {
                items += try await media(in: child, session: session, depth: depth - 1)
            } else if AlbumMedia.isMedia(child.name) {
                items.append(child)
            }
        }
        return AlbumMedia.newestFirst(items)
    }
}

enum AlbumMedia {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "gif", "webp"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "webm"]

    static func isImage(_ name: String) -> Bool { imageExtensions.contains((name as NSString).pathExtension.lowercased()) }
    static func isVideo(_ name: String) -> Bool { videoExtensions.contains((name as NSString).pathExtension.lowercased()) }
    static func isMedia(_ name: String) -> Bool { isImage(name) || isVideo(name) }

    /// Switch captures are named "YYYYMMDDhhmmssNN-<hash>.jpg".
    static func captureDate(_ object: MTPObject) -> Date? {
        let digits = object.name.prefix(14)
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return object.modified }
        let value = Array(digits)
        func int(_ range: Range<Int>) -> Int? { Int(String(value[range])) }
        let components = DateComponents(
            year: int(0..<4), month: int(4..<6), day: int(6..<8),
            hour: int(8..<10), minute: int(10..<12), second: int(12..<14)
        )
        return Calendar(identifier: .gregorian).date(from: components) ?? object.modified
    }

    static func newestFirst(_ items: [MTPObject]) -> [MTPObject] {
        items.sorted { (captureDate($0) ?? .distantPast) > (captureDate($1) ?? .distantPast) }
    }
}

/// Thumbnails for device media. Images use the device's own thumbnail when offered, else the preview
/// embedded near the start of the JPEG (read with a partial transfer), else a scaled-down full download.
/// Videos get a frame from AVFoundation, which reads only the byte ranges it needs over MTP.
/// Results are cached on disk, keyed by storage, name and size so they survive reconnects.
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("slopMTP/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var inFlight: [String: Task<Data?, Never>] = [:]

    private static let maxPixelSize = 480
    private static let headerBytes: UInt32 = 128 * 1024
    private static let maxFullDownload: UInt64 = 16 * 1024 * 1024
    /// Videos larger than this are skipped when the device can't serve partial reads.
    private static let maxFullVideoDownload: UInt64 = 128 * 1024 * 1024

    /// JPEG data for the thumbnail, or nil if none could be made.
    func thumbnail(for object: MTPObject, session: MTPSession) async -> Data? {
        let key = Self.key(for: object)
        let file = directory.appendingPathComponent(key + ".jpg")
        if let cached = try? Data(contentsOf: file) { return cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task<Data?, Never> {
            guard let data = await Self.makeThumbnail(for: object, session: session) else { return nil }
            try? data.write(to: file, options: .atomic)
            return data
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private static func makeThumbnail(for object: MTPObject, session: MTPSession) async -> Data? {
        if AlbumMedia.isVideo(object.name) {
            return await videoThumbnail(for: object, session: session)
        }
        if let data = try? await session.thumbnail(of: object.handle), let image = scaled(data, embeddedOnly: false) {
            return image
        }
        if let header = try? await session.partialData(of: object.handle, count: headerBytes),
           let image = scaled(header, embeddedOnly: true) {
            return image
        }
        guard object.size <= maxFullDownload, let full = try? await session.data(of: object.handle) else { return nil }
        return scaled(full, embeddedOnly: false)
    }

    /// Makes a JPEG thumbnail. With `embeddedOnly`, only an embedded (EXIF) preview is accepted,
    /// since the data may be a truncated prefix of the file.
    private static func scaled(_ data: Data, embeddedOnly: Bool) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: !embeddedOnly,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpeg(image)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// A frame from about a second into the video; if that's black (a fade-in), a later one.
    private static func videoThumbnail(for object: MTPObject, session: MTPSession) async -> Data? {
        var temporaryFile: URL?
        defer { if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) } }

        let asset: AVURLAsset
        let loader: MTPAssetLoader?
        if await session.canResume(object) {
            let custom = MTPAssetLoader(object: object, session: session)
            asset = AVURLAsset(url: custom.url)
            asset.resourceLoader.setDelegate(custom, queue: custom.queue)
            loader = custom
        } else {
            guard object.size <= maxFullVideoDownload else { return nil }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension((object.name as NSString).pathExtension)
            guard (try? await session.download(object, to: file)) != nil else { return nil }
            temporaryFile = file
            asset = AVURLAsset(url: file)
            loader = nil
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        var image: CGImage?
        for seconds in [1.0, 4.0, 10.0] {
            guard let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { break }
            image = frame
            if !isNearlyBlack(frame) { break }
        }
        withExtendedLifetime(loader) {}
        return image.flatMap(jpeg)
    }

    /// Averages the frame down to one pixel and checks its brightness.
    private static func isNearlyBlack(_ image: CGImage) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) < 3 * 16
    }

    private static func key(for object: MTPObject) -> String {
        let safe = object.name.replacingOccurrences(of: "/", with: "_")
        return "\(object.storageID)-\(object.size)-\(safe)"
    }
}

/// Serves an MTP object's bytes to AVFoundation on demand, using partial reads.
private final class MTPAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let object: MTPObject
    let session: MTPSession
    let queue = DispatchQueue(label: "slopMTP.MTPAssetLoader")
    let url: URL

    private static let chunkSize: Int64 = 1024 * 1024

    init(object: MTPObject, session: MTPSession) {
        self.object = object
        self.session = session
        let ext = (object.name as NSString).pathExtension.lowercased()
        url = URL(string: "slopmtp-media://object/\(object.storageID)/\(object.handle).\(ext.isEmpty ? "mp4" : ext)")!
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let size = Int64(object.size)
        if let info = loadingRequest.contentInformationRequest {
            let ext = (object.name as NSString).pathExtension.lowercased()
            info.contentType = (ext == "mov" ? AVFileType.mov : AVFileType.mp4).rawValue
            info.contentLength = size
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let start = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
        let end = dataRequest.requestsAllDataToEndOfResource
            ? size
            : min(size, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
        let request = UncheckedRequest(loadingRequest)
        let handle = object.handle
        let session = session
        let queue = queue

        Task {
            var offset = start
            do {
                while offset < end {
                    if request.value.isCancelled { return }
                    let count = UInt32(min(Self.chunkSize, end - offset))
                    let data = try await session.partialData(of: handle, offset: UInt64(offset), count: count)
                    guard !data.isEmpty else { break }
                    queue.sync { request.value.dataRequest?.respond(with: data) }
                    offset += Int64(data.count)
                }
                queue.sync { request.value.finishLoading() }
            } catch {
                queue.sync { request.value.finishLoading(with: error) }
            }
        }
        return true
    }
}

/// AVAssetResourceLoadingRequest isn't Sendable; it is only touched on the loader's queue.
private struct UncheckedRequest: @unchecked Sendable {
    let value: AVAssetResourceLoadingRequest
    init(_ value: AVAssetResourceLoadingRequest) { self.value = value }
}
