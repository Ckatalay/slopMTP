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
    public func contents(storageID: UInt32, parent: UInt32 = MTPConstants.rootParent) throws -> [MTPObject] {
        try objectHandles(storageID: storageID, parent: parent).map { handle in
            try Task.checkCancellation()
            return try object(handle)
        }
    }

    // MARK: - Download

    /// Streams an object's contents into a local file.
    public func download(_ object: MTPObject, to destination: URL, progress: MTPProgressHandler? = nil) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw MTPError.localFile("Could not create \(destination.lastPathComponent).")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            throw MTPError.localFile("Could not open \(destination.lastPathComponent) for writing: \(error.localizedDescription)")
        }

        var received: UInt64 = 0
        let total = object.size
        progress?(0, total)
        do {
            defer { try? handle.close() }
            try transaction(.getObject, [object.handle], dataPhase: .incoming { chunk in
                try handle.write(contentsOf: chunk)
                received += UInt64(chunk.count)
                progress?(received, max(total, received))
            })
            if let modified = object.modified {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
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
