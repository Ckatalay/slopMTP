import Foundation

/// A file or folder on the device.
public struct MTPObject: Identifiable, Hashable, Sendable {
    public var id: UInt32 { handle }
    public var handle: UInt32
    public var storageID: UInt32
    public var parent: UInt32
    public var name: String
    public var format: ObjectFormat
    public var size: UInt64
    public var modified: Date?

    public var isFolder: Bool { format == .association }

    public init(handle: UInt32, storageID: UInt32, parent: UInt32, name: String, format: ObjectFormat, size: UInt64, modified: Date?) {
        self.handle = handle
        self.storageID = storageID
        self.parent = parent
        self.name = name
        self.format = format
        self.size = size
        self.modified = modified
    }
}

public struct MTPStorage: Identifiable, Hashable, Sendable {
    public var id: UInt32
    public var info: StorageInfo

    public init(id: UInt32, info: StorageInfo) {
        self.id = id
        self.info = info
    }

    public static func == (lhs: MTPStorage, rhs: MTPStorage) -> Bool { lhs.id == rhs.id && lhs.info == rhs.info }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Reports `(bytesTransferred, totalBytes)`.
public typealias MTPProgressHandler = @Sendable (UInt64, UInt64) -> Void

extension MTPSession {
    // MARK: - Storage

    public func storageIDs() throws -> [UInt32] {
        var reader = PTPDataReader(try transactionData(.getStorageIDs))
        return try reader.readArray(UInt32.self)
    }

    public func storageInfo(_ storageID: UInt32) throws -> StorageInfo {
        try StorageInfo(parsing: try transactionData(.getStorageInfo, [storageID]))
    }

    public func storages() throws -> [MTPStorage] {
        try storageIDs().map { MTPStorage(id: $0, info: try storageInfo($0)) }
    }

    // MARK: - Objects

    /// Lists object handles. Pass `MTPConstants.rootParent` for the storage root.
    public func objectHandles(storageID: UInt32, parent: UInt32 = MTPConstants.rootParent, format: ObjectFormat = .any) throws -> [UInt32] {
        var reader = PTPDataReader(try transactionData(.getObjectHandles, [storageID, UInt32(format.rawValue), parent]))
        return try reader.readArray(UInt32.self)
    }

    public func objectInfo(_ handle: UInt32) throws -> ObjectInfo {
        try ObjectInfo(parsing: try transactionData(.getObjectInfo, [handle]))
    }

    public func objectPropertyValue(_ handle: UInt32, property: ObjectPropertyCode, type: PTPDataType) throws -> PTPValue {
        var reader = PTPDataReader(try transactionData(.getObjectPropValue, [handle, UInt32(property.rawValue)]))
        return try reader.readValue(of: type)
    }

    /// Returns the object's full 64-bit size, falling back to the 32-bit ObjectInfo size.
    public func objectSize(_ handle: UInt32, info: ObjectInfo) -> UInt64 {
        guard info.compressedSize == MTPConstants.sizeOverflow else { return UInt64(info.compressedSize) }
        if deviceInfo?.supports(.getObjectPropValue) ?? true,
           let size = try? objectPropertyValue(handle, property: .objectSize, type: .uint64).uint64 {
            return size
        }
        return UInt64(info.compressedSize)
    }

    public func object(_ handle: UInt32) throws -> MTPObject {
        let info = try objectInfo(handle)
        return MTPObject(
            handle: handle,
            storageID: info.storageID,
            parent: info.parentObject,
            name: info.filename,
            format: info.format,
            size: info.isFolder ? 0 : objectSize(handle, info: info),
            modified: PTPDate.parse(info.modificationDate) ?? PTPDate.parse(info.captureDate)
        )
    }

    /// Lists the direct children of `parent` (or the storage root).
    ///
    /// For larger folders this uses one `GetObjectPropList` request instead of one `GetObjectInfo`
    /// per child. The handle list stays authoritative: anything the property list leaves out or
    /// describes incompletely is fetched individually.
    public func contents(storageID: UInt32, parent: UInt32 = MTPConstants.rootParent) throws -> [MTPObject] {
        let handles = try objectHandles(storageID: storageID, parent: parent)
        var described: [UInt32: MTPObject] = [:]
        if handles.count >= Self.propListThreshold, canUsePropList {
            do {
                described = try objectsViaPropList(storageID: storageID, parent: parent, handles: Set(handles))
            } catch MTPError.response(let code, _) where [.operationNotSupported, .parameterNotSupported, .invalidObjectPropCode, .invalidParameter].contains(code) {
                propListUnsupported = true
            } catch let error as MTPError where error == .cancelled || error == .disconnected {
                throw error
            } catch {
                // Fall back to per-object requests below.
            }
        }
        return try handles.map { handle in
            try Task.checkCancellation()
            return try described[handle] ?? object(handle)
        }
    }

    static let propListThreshold = 4

    private var canUsePropList: Bool {
        !propListUnsupported && deviceInfo?.supports(.getObjectPropList) == true
    }

    /// Children of `parent` described by a single GetObjectPropList (all properties, depth 1).
    /// The root is addressed as handle 0, as MTP responders conventionally expect.
    private func objectsViaPropList(storageID: UInt32, parent: UInt32, handles: Set<UInt32>) throws -> [UInt32: MTPObject] {
        let queryHandle = parent == MTPConstants.rootParent ? 0 : parent
        let data = try transactionData(.getObjectPropList, [queryHandle, 0, 0xFFFF_FFFF, 0, 1])
        var reader = PTPDataReader(data)
        let count = Int(try reader.read(UInt32.self))
        guard count <= reader.remaining / 8 else {
            throw MTPError.malformedData("Property list claims \(count) elements")
        }

        var properties: [UInt32: [UInt16: PTPValue]] = [:]
        for _ in 0..<count {
            let handle: UInt32 = try reader.read()
            let code: UInt16 = try reader.read()
            let type: UInt16 = try reader.read()
            let value = try reader.readValue(rawType: type)
            if handles.contains(handle), let value {
                properties[handle, default: [:]][code] = value
            }
        }

        var objects: [UInt32: MTPObject] = [:]
        for (handle, props) in properties {
            guard let name = props[ObjectPropertyCode.objectFileName.rawValue]?.string,
                  let rawFormat = props[ObjectPropertyCode.objectFormat.rawValue]?.uint64
            else { continue }
            let format = ObjectFormat(UInt16(truncatingIfNeeded: rawFormat))
            let size = props[ObjectPropertyCode.objectSize.rawValue]?.uint64
            // Files need a size; without one, fall back to GetObjectInfo for this object.
            if format != .association && size == nil { continue }
            let objectStorage = props[ObjectPropertyCode.storageID.rawValue]?.uint64.map { UInt32(truncatingIfNeeded: $0) } ?? storageID
            let objectParent = props[ObjectPropertyCode.parentObject.rawValue]?.uint64.map { UInt32(truncatingIfNeeded: $0) }
                ?? (parent == MTPConstants.rootParent ? 0 : parent)
            let modified = props[ObjectPropertyCode.dateModified.rawValue]?.string.flatMap(PTPDate.parse)
            objects[handle] = MTPObject(
                handle: handle, storageID: objectStorage, parent: objectParent, name: name,
                format: format, size: format == .association ? 0 : size ?? 0, modified: modified
            )
        }
        return objects
    }

    // MARK: - Download

    /// Whether an interrupted download of `object` can continue where it stopped.
    public func canResume(_ object: MTPObject) -> Bool {
        guard let info = deviceInfo else { return false }
        return info.supports(.getPartialObject64) || (info.supports(.getPartialObject) && object.size <= UInt64(UInt32.max))
    }

    /// Streams an object's contents into a local file.
    ///
    /// Data goes to `<destination>.part`, tagged with the object it came from. If an earlier attempt
    /// left a matching partial file and the device supports partial reads, the download resumes from
    /// where it stopped. The partial file is kept on failure or cancellation so a retry can resume.
    public func download(_ object: MTPObject, to destination: URL, progress: MTPProgressHandler? = nil) throws {
        let partURL = PartialDownload.partURL(for: destination)
        let tag = PartialDownload.tag(for: object)
        let fileManager = FileManager.default

        var offset: UInt64 = 0
        if canResume(object), object.size > 0,
           let existing = PartialDownload.size(of: partURL), existing < object.size,
           PartialDownload.readTag(partURL) == tag {
            offset = existing
        } else {
            try? fileManager.removeItem(at: partURL)
            guard fileManager.createFile(atPath: partURL.path, contents: nil) else {
                throw MTPError.localFile("Could not create \(partURL.lastPathComponent).")
            }
            PartialDownload.writeTag(tag, to: partURL)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: partURL)
            try handle.truncate(atOffset: offset)
            try handle.seek(toOffset: offset)
        } catch {
            throw MTPError.localFile("Could not open \(partURL.lastPathComponent) for writing: \(error.localizedDescription)")
        }

        var received = offset
        let total = object.size
        progress?(received, total)
        let sink: (Data) throws -> Void = { chunk in
            try handle.write(contentsOf: chunk)
            received += UInt64(chunk.count)
            progress?(received, max(total, received))
        }

        do {
            defer { try? handle.close() }
            if offset == 0 {
                try transaction(.getObject, [object.handle], dataPhase: .incoming(sink))
            } else {
                try readPartially(object, from: offset, received: { received }, sink: sink)
            }
        }

        if total > 0, received != total {
            throw MTPError.malformedData("Received \(received) of \(total) bytes")
        }
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: partURL, to: destination)
        } catch {
            throw MTPError.localFile("Could not save \(destination.lastPathComponent): \(error.localizedDescription)")
        }
        PartialDownload.removeTag(from: destination)
        if let modified = object.modified {
            try? fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
        }
    }

    /// Reads the rest of an object in chunks with GetPartialObject64 (or the 32-bit GetPartialObject).
    private func readPartially(_ object: MTPObject, from start: UInt64, received: () -> UInt64, sink: @escaping (Data) throws -> Void) throws {
        let chunkSize: UInt64 = 64 << 20
        let use64 = deviceInfo?.supports(.getPartialObject64) == true
        while received() < object.size {
            try Task.checkCancellation()
            let position = received()
            let count = UInt32(min(chunkSize, object.size - position))
            if use64 {
                try transaction(.getPartialObject64, [object.handle, UInt32(position & 0xFFFF_FFFF), UInt32(position >> 32), count], dataPhase: .incoming(sink))
            } else {
                try transaction(.getPartialObject, [object.handle, UInt32(position), count], dataPhase: .incoming(sink))
            }
            if received() == position {
                throw MTPError.malformedData("The device returned no data at offset \(position)")
            }
        }
    }

    /// Reads an object fully into memory. Intended for small files.
    public func data(of handle: UInt32) throws -> Data {
        try transactionData(.getObject, [handle])
    }

    // MARK: - Upload

    /// Uploads a local file into `parent` (or the storage root) and returns the new object handle.
    @discardableResult
    public func upload(
        _ source: URL,
        storageID: UInt32,
        parent: UInt32 = MTPConstants.rootParent,
        name: String? = nil,
        progress: MTPProgressHandler? = nil
    ) throws -> UInt32 {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        } catch {
            throw MTPError.localFile("Could not read \(source.lastPathComponent): \(error.localizedDescription)")
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date
        let filename = name ?? source.lastPathComponent

        let file: FileHandle
        do {
            file = try FileHandle(forReadingFrom: source)
        } catch {
            throw MTPError.localFile("Could not open \(source.lastPathComponent): \(error.localizedDescription)")
        }
        defer { try? file.close() }

        let handle = try createObject(
            name: filename, format: .undefined, size: size, modified: modified,
            storageID: storageID, parent: parent
        )

        var sent: UInt64 = 0
        progress?(0, size)
        let dataSource = DataSource(length: size) { count in
            let chunk = try file.read(upToCount: count) ?? Data()
            sent += UInt64(chunk.count)
            progress?(sent, size)
            return chunk
        }
        try transaction(.sendObject, dataPhase: .outgoing(dataSource), responseTimeout: timeouts.responseAfterData)
        return handle
    }

    /// Uploads in-memory data as a file.
    @discardableResult
    public func upload(data: Data, name: String, storageID: UInt32, parent: UInt32 = MTPConstants.rootParent) throws -> UInt32 {
        let handle = try createObject(name: name, format: .undefined, size: UInt64(data.count), modified: Date(), storageID: storageID, parent: parent)
        try transaction(.sendObject, dataPhase: .outgoing(.memory(data)), responseTimeout: timeouts.responseAfterData)
        return handle
    }

    @discardableResult
    public func createFolder(name: String, storageID: UInt32, parent: UInt32 = MTPConstants.rootParent) throws -> UInt32 {
        try createObject(name: name, format: .association, size: 0, modified: Date(), storageID: storageID, parent: parent)
    }

    /// Announces a new object with SendObjectInfo (or SendObjectPropList for objects ≥ 4 GiB when
    /// supported, since only it carries a 64-bit size). Returns the handle assigned by the device.
    private func createObject(name: String, format: ObjectFormat, size: UInt64, modified: Date?, storageID: UInt32, parent: UInt32) throws -> UInt32 {
        let response: PTPResponse
        if size > UInt64(UInt32.max) - 1, deviceInfo?.supports(.sendObjectPropList) == true {
            let props = ObjectPropListElement.encode([
                ObjectPropListElement(property: .objectFileName, dataType: .string, value: .string(name)),
            ])
            response = try transaction(
                .sendObjectPropList,
                [storageID, parent, UInt32(format.rawValue), UInt32(size >> 32), UInt32(size & 0xFFFF_FFFF)],
                dataPhase: .outgoing(.memory(props))
            )
        } else {
            let info = ObjectInfo(
                storageID: storageID,
                format: format,
                compressedSize: size >= UInt64(MTPConstants.sizeOverflow) ? MTPConstants.sizeOverflow : UInt32(size),
                parentObject: parent == MTPConstants.rootParent ? 0 : parent,
                associationType: format == .association ? MTPConstants.genericFolder : 0,
                filename: name,
                modificationDate: modified.map(PTPDate.format) ?? ""
            )
            response = try transaction(.sendObjectInfo, [storageID, parent], dataPhase: .outgoing(.memory(info.encoded)))
        }
        guard response.parameters.count >= 3 else {
            throw MTPError.malformedData("Object creation response is missing the new handle")
        }
        return response.parameters[2]
    }

    // MARK: - Modify

    public func delete(_ handle: UInt32) throws {
        try transaction(.deleteObject, [handle, 0])
    }

    public func rename(_ handle: UInt32, to name: String) throws {
        guard deviceInfo?.supports(.setObjectPropValue) ?? true else {
            throw MTPError.operationNotSupported(.setObjectPropValue)
        }
        var writer = PTPDataWriter()
        writer.writeString(name)
        try transaction(.setObjectPropValue, [handle, UInt32(ObjectPropertyCode.objectFileName.rawValue)], dataPhase: .outgoing(.memory(writer.data)))
    }
}

/// Bookkeeping for `.part` files: an extended attribute records which object a partial file
/// belongs to, so a retry only resumes into data from the same source.
enum PartialDownload {
    static let attribute = "io.github.ckatalay.slopmtp.source"

    static func partURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".part")
    }

    /// Handles change between sessions, so identify the source by storage, name and size.
    static func tag(for object: MTPObject) -> String {
        "\(object.storageID):\(object.size):\(object.name)"
    }

    static func size(of url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    static func writeTag(_ tag: String, to url: URL) {
        let bytes = Array(tag.utf8)
        _ = setxattr(url.path, attribute, bytes, bytes.count, 0, 0)
    }

    static func readTag(_ url: URL) -> String? {
        let length = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        guard getxattr(url.path, attribute, &bytes, length, 0, 0) == length else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func removeTag(from url: URL) {
        _ = removexattr(url.path, attribute, 0)
    }
}
