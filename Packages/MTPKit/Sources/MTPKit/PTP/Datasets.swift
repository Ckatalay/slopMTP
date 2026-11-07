import Foundation

/// The DeviceInfo dataset returned by `GetDeviceInfo`.
public struct DeviceInfo: Equatable, Sendable {
    public var standardVersion: UInt16
    public var vendorExtensionID: UInt32
    public var vendorExtensionVersion: UInt16
    public var vendorExtensionDescription: String
    public var functionalMode: UInt16
    public var operationsSupported: Set<OperationCode>
    public var eventsSupported: [UInt16]
    public var devicePropertiesSupported: [UInt16]
    public var captureFormats: [UInt16]
    public var playbackFormats: [UInt16]
    public var manufacturer: String
    public var model: String
    public var deviceVersion: String
    public var serialNumber: String

    public init(parsing data: Data) throws {
        var r = PTPDataReader(data)
        standardVersion = try r.read()
        vendorExtensionID = try r.read()
        vendorExtensionVersion = try r.read()
        vendorExtensionDescription = try r.readString()
        functionalMode = try r.read()
        operationsSupported = Set(try r.readArray(UInt16.self).map(OperationCode.init(rawValue:)))
        eventsSupported = try r.readArray()
        devicePropertiesSupported = try r.readArray()
        captureFormats = try r.readArray()
        playbackFormats = try r.readArray()
        manufacturer = try r.readString()
        model = try r.readString()
        deviceVersion = try r.readString()
        serialNumber = try r.readString()
    }

    public func supports(_ operation: OperationCode) -> Bool {
        operationsSupported.contains(operation)
    }
}

/// The StorageInfo dataset returned by `GetStorageInfo`.
public struct StorageInfo: Equatable, Sendable {
    public var storageType: UInt16
    public var filesystemType: UInt16
    public var accessCapability: UInt16
    public var maxCapacity: UInt64
    public var freeSpaceInBytes: UInt64
    public var freeSpaceInObjects: UInt32
    public var storageDescription: String
    public var volumeLabel: String

    public init(parsing data: Data) throws {
        var r = PTPDataReader(data)
        storageType = try r.read()
        filesystemType = try r.read()
        accessCapability = try r.read()
        maxCapacity = try r.read()
        freeSpaceInBytes = try r.read()
        freeSpaceInObjects = try r.read()
        storageDescription = try r.readString()
        volumeLabel = (try? r.readString()) ?? ""
    }

    /// 0 = read-write, 1 = read-only without delete, 2 = read-only with delete.
    public var isReadOnly: Bool { accessCapability != 0 }

    public var displayName: String {
        if !storageDescription.isEmpty { return storageDescription }
        if !volumeLabel.isEmpty { return volumeLabel }
        return "Storage"
    }
}

/// The ObjectInfo dataset used by `GetObjectInfo` and `SendObjectInfo`.
public struct ObjectInfo: Equatable, Sendable {
    public var storageID: UInt32
    public var format: ObjectFormat
    public var protectionStatus: UInt16
    /// 32-bit size; `0xFFFFFFFF` for objects of 4 GiB or more.
    public var compressedSize: UInt32
    public var thumbFormat: UInt16
    public var thumbCompressedSize: UInt32
    public var thumbPixWidth: UInt32
    public var thumbPixHeight: UInt32
    public var imagePixWidth: UInt32
    public var imagePixHeight: UInt32
    public var imageBitDepth: UInt32
    public var parentObject: UInt32
    public var associationType: UInt16
    public var associationDescription: UInt32
    public var sequenceNumber: UInt32
    public var filename: String
    public var captureDate: String
    public var modificationDate: String
    public var keywords: String

    public init(
        storageID: UInt32,
        format: ObjectFormat,
        compressedSize: UInt32,
        parentObject: UInt32,
        associationType: UInt16 = 0,
        filename: String,
        modificationDate: String = ""
    ) {
        self.storageID = storageID
        self.format = format
        protectionStatus = 0
        self.compressedSize = compressedSize
        thumbFormat = 0
        thumbCompressedSize = 0
        thumbPixWidth = 0
        thumbPixHeight = 0
        imagePixWidth = 0
        imagePixHeight = 0
        imageBitDepth = 0
        self.parentObject = parentObject
        self.associationType = associationType
        associationDescription = 0
        sequenceNumber = 0
        self.filename = filename
        captureDate = ""
        self.modificationDate = modificationDate
        keywords = ""
    }

    public init(parsing data: Data) throws {
        var r = PTPDataReader(data)
        storageID = try r.read()
        format = ObjectFormat(try r.read(UInt16.self))
        protectionStatus = try r.read()
        compressedSize = try r.read()
        thumbFormat = try r.read()
        thumbCompressedSize = try r.read()
        thumbPixWidth = try r.read()
        thumbPixHeight = try r.read()
        imagePixWidth = try r.read()
        imagePixHeight = try r.read()
        imageBitDepth = try r.read()
        parentObject = try r.read()
        associationType = try r.read()
        associationDescription = try r.read()
        sequenceNumber = try r.read()
        filename = try r.readString()
        // Some responders truncate the trailing strings; treat them as optional.
        captureDate = (try? r.readString()) ?? ""
        modificationDate = (try? r.readString()) ?? ""
        keywords = (try? r.readString()) ?? ""
    }

    public var encoded: Data {
        var w = PTPDataWriter()
        w.write(storageID)
        w.write(format.rawValue)
        w.write(protectionStatus)
        w.write(compressedSize)
        w.write(thumbFormat)
        w.write(thumbCompressedSize)
        w.write(thumbPixWidth)
        w.write(thumbPixHeight)
        w.write(imagePixWidth)
        w.write(imagePixHeight)
        w.write(imageBitDepth)
        w.write(parentObject)
        w.write(associationType)
        w.write(associationDescription)
        w.write(sequenceNumber)
        w.writeString(filename)
        w.writeString(captureDate)
        w.writeString(modificationDate)
        w.writeString(keywords)
        return w.data
    }

    public var isFolder: Bool { format == .association }
}

/// A single entry in an ObjectPropList dataset.
public struct ObjectPropListElement: Sendable {
    public var handle: UInt32
    public var property: ObjectPropertyCode
    public var dataType: PTPDataType
    public var value: PTPValue

    public init(handle: UInt32 = 0, property: ObjectPropertyCode, dataType: PTPDataType, value: PTPValue) {
        self.handle = handle
        self.property = property
        self.dataType = dataType
        self.value = value
    }

    static func encode(_ elements: [ObjectPropListElement]) -> Data {
        var w = PTPDataWriter()
        w.write(UInt32(elements.count))
        for e in elements {
            w.write(e.handle)
            w.write(e.property.rawValue)
            w.write(e.dataType.rawValue)
            switch (e.dataType, e.value) {
            case (.string, .string(let s)): w.writeString(s)
            case (.uint8, let v): w.write(UInt8(truncatingIfNeeded: v.uint64 ?? 0))
            case (.uint16, let v): w.write(UInt16(truncatingIfNeeded: v.uint64 ?? 0))
            case (.uint32, let v): w.write(UInt32(truncatingIfNeeded: v.uint64 ?? 0))
            case (.uint64, let v): w.write(v.uint64 ?? 0)
            default: w.write(UInt32(0))
            }
        }
        return w.data
    }
}
