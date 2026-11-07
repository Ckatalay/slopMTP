import Foundation

/// PTP / MTP operation codes (PIMA 15740 + MTP 1.1 extensions).
public struct OperationCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public static let getDeviceInfo = OperationCode(0x1001)
    public static let openSession = OperationCode(0x1002)
    public static let closeSession = OperationCode(0x1003)
    public static let getStorageIDs = OperationCode(0x1004)
    public static let getStorageInfo = OperationCode(0x1005)
    public static let getNumObjects = OperationCode(0x1006)
    public static let getObjectHandles = OperationCode(0x1007)
    public static let getObjectInfo = OperationCode(0x1008)
    public static let getObject = OperationCode(0x1009)
    public static let getThumb = OperationCode(0x100A)
    public static let deleteObject = OperationCode(0x100B)
    public static let sendObjectInfo = OperationCode(0x100C)
    public static let sendObject = OperationCode(0x100D)
    public static let getDevicePropDesc = OperationCode(0x1014)
    public static let getDevicePropValue = OperationCode(0x1015)
    public static let moveObject = OperationCode(0x1019)
    public static let copyObject = OperationCode(0x101A)
    public static let getPartialObject = OperationCode(0x101B)

    // MTP extensions
    public static let getObjectPropsSupported = OperationCode(0x9801)
    public static let getObjectPropDesc = OperationCode(0x9802)
    public static let getObjectPropValue = OperationCode(0x9803)
    public static let setObjectPropValue = OperationCode(0x9804)
    public static let getObjectPropList = OperationCode(0x9805)
    public static let setObjectPropList = OperationCode(0x9806)
    public static let sendObjectPropList = OperationCode(0x9808)
    public static let getPartialObject64 = OperationCode(0x95C1)

    public var description: String {
        let names: [UInt16: String] = [
            0x1001: "GetDeviceInfo", 0x1002: "OpenSession", 0x1003: "CloseSession",
            0x1004: "GetStorageIDs", 0x1005: "GetStorageInfo", 0x1006: "GetNumObjects",
            0x1007: "GetObjectHandles", 0x1008: "GetObjectInfo", 0x1009: "GetObject",
            0x100A: "GetThumb", 0x100B: "DeleteObject", 0x100C: "SendObjectInfo",
            0x100D: "SendObject", 0x1014: "GetDevicePropDesc", 0x1015: "GetDevicePropValue",
            0x1019: "MoveObject", 0x101A: "CopyObject", 0x101B: "GetPartialObject",
            0x9801: "GetObjectPropsSupported", 0x9802: "GetObjectPropDesc",
            0x9803: "GetObjectPropValue", 0x9804: "SetObjectPropValue",
            0x9805: "GetObjectPropList", 0x9806: "SetObjectPropList",
            0x9808: "SendObjectPropList", 0x95C1: "GetPartialObject64",
        ]
        return names[rawValue] ?? String(format: "Operation 0x%04X", rawValue)
    }
}

/// PTP / MTP response codes.
public struct ResponseCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public static let ok = ResponseCode(0x2001)
    public static let generalError = ResponseCode(0x2002)
    public static let sessionNotOpen = ResponseCode(0x2003)
    public static let invalidTransactionID = ResponseCode(0x2004)
    public static let operationNotSupported = ResponseCode(0x2005)
    public static let parameterNotSupported = ResponseCode(0x2006)
    public static let incompleteTransfer = ResponseCode(0x2007)
    public static let invalidStorageID = ResponseCode(0x2008)
    public static let invalidObjectHandle = ResponseCode(0x2009)
    public static let devicePropNotSupported = ResponseCode(0x200A)
    public static let invalidObjectFormatCode = ResponseCode(0x200B)
    public static let storageFull = ResponseCode(0x200C)
    public static let objectWriteProtected = ResponseCode(0x200D)
    public static let storeReadOnly = ResponseCode(0x200E)
    public static let accessDenied = ResponseCode(0x200F)
    public static let noThumbnailPresent = ResponseCode(0x2010)
    public static let deviceBusy = ResponseCode(0x2019)
    public static let invalidParentObject = ResponseCode(0x201A)
    public static let invalidParameter = ResponseCode(0x201D)
    public static let sessionAlreadyOpen = ResponseCode(0x201E)
    public static let transactionCancelled = ResponseCode(0x201F)
    public static let invalidObjectPropCode = ResponseCode(0xA801)
    public static let invalidObjectPropFormat = ResponseCode(0xA802)
    public static let objectTooLarge = ResponseCode(0xA809)

    public var description: String {
        let names: [UInt16: String] = [
            0x2001: "OK", 0x2002: "General error", 0x2003: "Session not open",
            0x2004: "Invalid transaction ID", 0x2005: "Operation not supported",
            0x2006: "Parameter not supported", 0x2007: "Incomplete transfer",
            0x2008: "Invalid storage ID", 0x2009: "Invalid object handle",
            0x200A: "Device property not supported", 0x200B: "Invalid object format",
            0x200C: "Storage full", 0x200D: "Object write-protected",
            0x200E: "Storage is read-only", 0x200F: "Access denied",
            0x2010: "No thumbnail present", 0x2019: "Device busy",
            0x201A: "Invalid parent object", 0x201D: "Invalid parameter",
            0x201E: "Session already open", 0x201F: "Transaction cancelled",
            0xA801: "Invalid object property code", 0xA802: "Invalid object property format",
            0xA809: "Object too large",
        ]
        return names[rawValue] ?? String(format: "Response 0x%04X", rawValue)
    }
    /// The response's meaning in the user's language, for error messages.
    public var localizedDescription: String {
        switch rawValue {
        case 0x2001: return L("OK", comment: "MTP device response")
        case 0x2002: return L("General error", comment: "MTP device response")
        case 0x2003: return L("Session not open", comment: "MTP device response")
        case 0x2004: return L("Invalid transaction ID", comment: "MTP device response")
        case 0x2005: return L("Operation not supported", comment: "MTP device response")
        case 0x2006: return L("Parameter not supported", comment: "MTP device response")
        case 0x2007: return L("Incomplete transfer", comment: "MTP device response")
        case 0x2008: return L("Invalid storage ID", comment: "MTP device response")
        case 0x2009: return L("Invalid object handle", comment: "MTP device response")
        case 0x200A: return L("Device property not supported", comment: "MTP device response")
        case 0x200B: return L("Invalid object format", comment: "MTP device response")
        case 0x200C: return L("Storage full", comment: "MTP device response")
        case 0x200D: return L("Object write-protected", comment: "MTP device response")
        case 0x200E: return L("Storage is read-only", comment: "MTP device response")
        case 0x200F: return L("Access denied", comment: "MTP device response")
        case 0x2010: return L("No thumbnail present", comment: "MTP device response")
        case 0x2019: return L("Device busy", comment: "MTP device response")
        case 0x201A: return L("Invalid parent object", comment: "MTP device response")
        case 0x201D: return L("Invalid parameter", comment: "MTP device response")
        case 0x201E: return L("Session already open", comment: "MTP device response")
        case 0x201F: return L("Transaction cancelled", comment: "MTP device response")
        case 0xA801: return L("Invalid object property code", comment: "MTP device response")
        case 0xA802: return L("Invalid object property format", comment: "MTP device response")
        case 0xA809: return L("Object too large", comment: "MTP device response")
        default: return String(format: "0x%04X", rawValue)
        }
    }
}

/// PTP / MTP event codes.
public struct EventCode: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public static let cancelTransaction = EventCode(0x4001)
    public static let objectAdded = EventCode(0x4002)
    public static let objectRemoved = EventCode(0x4003)
    public static let storeAdded = EventCode(0x4004)
    public static let storeRemoved = EventCode(0x4005)
    public static let devicePropChanged = EventCode(0x4006)
    public static let objectInfoChanged = EventCode(0x4007)
    public static let deviceInfoChanged = EventCode(0x4008)
    public static let storeFull = EventCode(0x400A)
    public static let storageInfoChanged = EventCode(0x400C)
    public static let objectPropChanged = EventCode(0xC801)
}

/// Object format codes.
public struct ObjectFormat: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public static let any = ObjectFormat(0x0000)
    public static let undefined = ObjectFormat(0x3000)
    public static let association = ObjectFormat(0x3001)
}

/// MTP object property codes.
public struct ObjectPropertyCode: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public static let storageID = ObjectPropertyCode(0xDC01)
    public static let objectFormat = ObjectPropertyCode(0xDC02)
    public static let objectSize = ObjectPropertyCode(0xDC04)
    public static let objectFileName = ObjectPropertyCode(0xDC07)
    public static let dateModified = ObjectPropertyCode(0xDC09)
    public static let parentObject = ObjectPropertyCode(0xDC0B)
    public static let name = ObjectPropertyCode(0xDC44)
}

/// PTP data type codes used in property datasets.
public enum PTPDataType: UInt16, Sendable {
    case int8 = 0x0001, uint8 = 0x0002, int16 = 0x0003, uint16 = 0x0004
    case int32 = 0x0005, uint32 = 0x0006, int64 = 0x0007, uint64 = 0x0008
    case int128 = 0x0009, uint128 = 0x000A
    case string = 0xFFFF
}

/// Well-known handle / parameter values.
public enum MTPConstants {
    /// `GetObjectHandles` parent parameter meaning "root of the storage".
    public static let rootParent: UInt32 = 0xFFFF_FFFF
    /// `GetObjectHandles` storage parameter meaning "all storages".
    public static let allStorages: UInt32 = 0xFFFF_FFFF
    /// Value used in 32-bit size fields for objects of 4 GiB or more.
    public static let sizeOverflow: UInt32 = 0xFFFF_FFFF
    /// Association type for a generic folder.
    public static let genericFolder: UInt16 = 0x0001
}
