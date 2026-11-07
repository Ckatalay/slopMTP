import Foundation

/// Little-endian serializer for PTP datasets.
public struct PTPDataWriter: Sendable {
    public private(set) var data = Data()

    public init() {}

    public mutating func write<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// PTP string: UInt8 character count (including the NUL terminator) followed by UTF-16LE code units.
    public mutating func writeString(_ string: String) {
        guard !string.isEmpty else {
            write(UInt8(0))
            return
        }
        var units = Array(string.utf16.prefix(254))
        units.append(0)
        write(UInt8(units.count))
        for unit in units { write(unit) }
    }

    public mutating func writeArray<T: FixedWidthInteger>(_ values: [T]) {
        write(UInt32(values.count))
        for value in values { write(value) }
    }

    public mutating func append(_ other: Data) {
        data.append(other)
    }
}

/// Little-endian deserializer for PTP datasets.
public struct PTPDataReader: Sendable {
    private let bytes: [UInt8]
    public private(set) var offset = 0

    public init(_ data: Data) {
        bytes = [UInt8](data)
    }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { remaining <= 0 }

    public mutating func read<T: FixedWidthInteger>(_: T.Type = T.self) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else {
            throw MTPError.malformedData("Needed \(size) bytes at offset \(offset), only \(remaining) left")
        }
        var value: T = 0
        for i in 0..<size {
            value |= T(truncatingIfNeeded: bytes[offset + i]) << (8 * i)
        }
        offset += size
        return value
    }

    public mutating func readString() throws -> String {
        let count = Int(try read(UInt8.self))
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count {
            units.append(try read(UInt16.self))
        }
        if let nul = units.firstIndex(of: 0) {
            units.removeSubrange(nul...)
        }
        return String(decoding: units, as: UTF16.self)
    }

    public mutating func readArray<T: FixedWidthInteger>(_: T.Type = T.self) throws -> [T] {
        let count = Int(try read(UInt32.self))
        guard count <= remaining / max(MemoryLayout<T>.size, 1) else {
            throw MTPError.malformedData("Array of \(count) elements exceeds remaining \(remaining) bytes")
        }
        return try (0..<count).map { _ in try read(T.self) }
    }

    public mutating func skip(_ count: Int) throws {
        guard remaining >= count else {
            throw MTPError.malformedData("Cannot skip \(count) bytes, only \(remaining) left")
        }
        offset += count
    }

    /// Reads a value of the given PTP data type, returning it as a number or string.
    public mutating func readValue(of type: PTPDataType) throws -> PTPValue {
        switch type {
        case .int8: return .int(Int64(try read(Int8.self)))
        case .uint8: return .uint(UInt64(try read(UInt8.self)))
        case .int16: return .int(Int64(try read(Int16.self)))
        case .uint16: return .uint(UInt64(try read(UInt16.self)))
        case .int32: return .int(Int64(try read(Int32.self)))
        case .uint32: return .uint(UInt64(try read(UInt32.self)))
        case .int64: return .int(try read(Int64.self))
        case .uint64: return .uint(try read(UInt64.self))
        case .int128, .uint128:
            let low = try read(UInt64.self)
            _ = try read(UInt64.self)
            return .uint(low)
        case .string: return .string(try readString())
        }
    }
}

public enum PTPValue: Sendable, Equatable {
    case int(Int64)
    case uint(UInt64)
    case string(String)

    public var uint64: UInt64? {
        switch self {
        case .uint(let v): return v
        case .int(let v): return v >= 0 ? UInt64(v) : nil
        case .string: return nil
        }
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// PTP date strings: "YYYYMMDDThhmmss[.s][Z|+hhmm|-hhmm]".
public enum PTPDate {
    public static func parse(_ string: String) -> Date? {
        guard string.count >= 15 else { return nil }
        let chars = Array(string)
        func int(_ range: Range<Int>) -> Int? { Int(String(chars[range])) }
        guard chars[8] == "T",
              let year = int(0..<4), let month = int(4..<6), let day = int(6..<8),
              let hour = int(9..<11), let minute = int(11..<13), let second = int(13..<15)
        else { return nil }

        var components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        var rest = chars[15...]
        if rest.first == "." {
            rest = rest.drop(while: { $0 == "." || $0.isNumber })
        }
        if rest.first == "Z" {
            components.timeZone = TimeZone(secondsFromGMT: 0)
        } else if let sign = rest.first, sign == "+" || sign == "-", rest.count >= 5 {
            let digits = Array(rest.dropFirst().prefix(4))
            if let h = Int(String(digits[0..<2])), let m = Int(String(digits[2..<4])) {
                let offset = (h * 3600 + m * 60) * (sign == "-" ? -1 : 1)
                components.timeZone = TimeZone(secondsFromGMT: offset)
            }
        } else {
            components.timeZone = .current
        }
        return Calendar(identifier: .gregorian).date(from: components)
    }

    public static func format(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let c = calendar.dateComponents(in: .current, from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02d",
                      c.year ?? 1970, c.month ?? 1, c.day ?? 1,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
