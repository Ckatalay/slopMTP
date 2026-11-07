import Foundation

/// A Nintendo Switch title ID.
///
/// - Application (base game): low 13 bits are zero, e.g. `010076F0049A2000`.
/// - Update (patch): application ID | `0x800`, e.g. `010076F0049A2800`.
/// - DLC (add-on content): application ID | `0x1000` + index, e.g. `010076F0049A3001`.
struct TitleID: Hashable, Comparable, Sendable, CustomStringConvertible {
    enum Kind: Int, Comparable, Sendable {
        case application = 0
        case update = 1
        case addOn = 2

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .application: return "Base Game"
            case .update: return "Update"
            case .addOn: return "DLC"
            }
        }
    }

    let rawValue: UInt64

    init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init?(hex: some StringProtocol) {
        guard hex.count == 16, let value = UInt64(hex, radix: 16) else { return nil }
        rawValue = value
    }

    var kind: Kind {
        if rawValue & 0x1FFF == 0x800 { return .update }
        if rawValue & 0x1000 != 0 { return .addOn }
        return .application
    }

    /// The base game this title belongs to.
    var applicationID: TitleID {
        switch kind {
        case .application: return self
        case .update: return TitleID(rawValue & ~0xFFF)
        case .addOn: return TitleID(rawValue & ~0x1FFF)
        }
    }

    var updateID: TitleID { TitleID(applicationID.rawValue | 0x800) }

    var description: String { String(format: "%016llX", rawValue) }

    static func < (lhs: TitleID, rhs: TitleID) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum TitleVersion {
    /// Title versions are stored as `release << 16`; v65536 is the first update.
    static func display(_ version: UInt32) -> String {
        version == 0 ? "v0" : "v\(version) (#\(version >> 16))"
    }

    static func short(_ version: UInt32) -> String {
        "v\(version >> 16)"
    }
}
