import Foundation

public enum PTPContainerType: UInt16, Sendable {
    case undefined = 0
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

/// The 12-byte header shared by every PTP USB container.
public struct PTPContainerHeader: Equatable, Sendable {
    public static let size = 12
    /// Used in the length field when the payload does not fit in 32 bits.
    public static let unknownLength: UInt32 = 0xFFFF_FFFF

    public var length: UInt32
    public var type: PTPContainerType
    public var code: UInt16
    public var transactionID: UInt32

    public init(length: UInt32, type: PTPContainerType, code: UInt16, transactionID: UInt32) {
        self.length = length
        self.type = type
        self.code = code
        self.transactionID = transactionID
    }

    public init(parsing data: Data) throws {
        guard data.count >= Self.size else {
            throw MTPError.malformedData("Container shorter than header (\(data.count) bytes)")
        }
        var reader = PTPDataReader(data.prefix(Self.size))
        length = try reader.read()
        let rawType: UInt16 = try reader.read()
        guard let type = PTPContainerType(rawValue: rawType) else {
            throw MTPError.malformedData("Unknown container type \(rawType)")
        }
        self.type = type
        code = try reader.read()
        transactionID = try reader.read()
    }

    public var encoded: Data {
        var writer = PTPDataWriter()
        writer.write(length)
        writer.write(type.rawValue)
        writer.write(code)
        writer.write(transactionID)
        return writer.data
    }
}

public enum PTPContainer {
    /// Encodes a command or response container (header + up to five UInt32 parameters).
    public static func encode(type: PTPContainerType, code: UInt16, transactionID: UInt32, parameters: [UInt32]) -> Data {
        precondition(parameters.count <= 5, "PTP containers carry at most five parameters")
        let length = UInt32(PTPContainerHeader.size + parameters.count * 4)
        var writer = PTPDataWriter()
        writer.append(PTPContainerHeader(length: length, type: type, code: code, transactionID: transactionID).encoded)
        for parameter in parameters { writer.write(parameter) }
        return writer.data
    }

    /// Reads the parameters following a header in a command / response / event container.
    public static func parameters(in data: Data, header: PTPContainerHeader) throws -> [UInt32] {
        let declared = min(Int(header.length), data.count)
        let parameterBytes = max(0, declared - PTPContainerHeader.size)
        var reader = PTPDataReader(data.dropFirst(PTPContainerHeader.size).prefix(parameterBytes))
        var parameters: [UInt32] = []
        while reader.remaining >= 4 && parameters.count < 5 {
            parameters.append(try reader.read())
        }
        return parameters
    }
}

public struct PTPResponse: Equatable, Sendable {
    public var code: ResponseCode
    public var transactionID: UInt32
    public var parameters: [UInt32]

    public init(code: ResponseCode, transactionID: UInt32, parameters: [UInt32]) {
        self.code = code
        self.transactionID = transactionID
        self.parameters = parameters
    }

    public init(parsing data: Data) throws {
        let header = try PTPContainerHeader(parsing: data)
        guard header.type == .response else {
            throw MTPError.unexpectedContainer("Expected response, got \(header.type)")
        }
        code = ResponseCode(header.code)
        transactionID = header.transactionID
        parameters = try PTPContainer.parameters(in: data, header: header)
    }
}

public struct PTPEvent: Equatable, Sendable {
    public var code: UInt16
    public var transactionID: UInt32
    public var parameters: [UInt32]

    public var eventCode: EventCode { EventCode(code) }

    public init(parsing data: Data) throws {
        let header = try PTPContainerHeader(parsing: data)
        guard header.type == .event else {
            throw MTPError.unexpectedContainer("Expected event, got \(header.type)")
        }
        code = header.code
        transactionID = header.transactionID
        parameters = try PTPContainer.parameters(in: data, header: header)
    }
}
