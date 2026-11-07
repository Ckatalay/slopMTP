import Foundation

/// Metadata recovered from a Switch content file name, e.g.
/// `Bayonetta [010076F0049A2800][v65536] (0.20 GB).nsz` or DBI's `SUPER MARIO ODYSSEY [B+U393216+1DLC].nsp`.
struct SwitchFileInfo: Hashable, Sendable {
    static let installableExtensions: Set<String> = ["nsp", "nsz", "xci", "xcz", "msp"]

    var title: String
    var titleID: TitleID?
    var version: UInt32?
    /// Explicit `[BASE]` / `[UPD]` / `[DLC]` tags.
    var taggedKind: TitleID.Kind?
    /// DBI's merged-dump summary (`[B+U393216+2DLC]`).
    var summary: DBISummary?
    var fileExtension: String

    struct DBISummary: Hashable, Sendable {
        var hasBase: Bool
        var updateVersion: UInt32?
        var dlcCount: Int
    }

    var kind: TitleID.Kind? { titleID?.kind ?? taggedKind }
    var isInstallable: Bool { Self.installableExtensions.contains(fileExtension) }
    /// NSZ / XCZ must be decompressed on the console, which DBI only does in title mode.
    var isCompressed: Bool { fileExtension == "nsz" || fileExtension == "xcz" }

    static let titleModeHint = "Compressed games (NSZ/XCZ) need DBI running in title mode: hold R while launching any game to start DBI, instead of opening it from the Album. In applet mode the console doesn't have enough memory to decompress them."

    init(fileName: String) {
        let ns = fileName as NSString
        fileExtension = ns.pathExtension.lowercased()
        let stem = SwitchFileInfo.installableExtensions.contains(fileExtension) || fileExtension == "nca"
            ? ns.deletingPathExtension : fileName

        var titleID: TitleID?
        var version: UInt32?
        var taggedKind: TitleID.Kind?
        var summary: DBISummary?

        for tag in SwitchFileInfo.bracketedTags(in: stem) {
            let upper = tag.uppercased()
            if titleID == nil, let id = TitleID(hex: tag) {
                titleID = id
            } else if version == nil, upper.hasPrefix("V"), let v = UInt32(upper.dropFirst()) {
                version = v
            } else if ["BASE", "APP"].contains(upper) {
                taggedKind = .application
            } else if ["UPD", "UPDATE", "PATCH"].contains(upper) {
                taggedKind = .update
            } else if ["DLC", "ADDON", "AOC"].contains(upper) {
                taggedKind = .addOn
            } else if summary == nil, let parsed = SwitchFileInfo.parseSummary(upper) {
                summary = parsed
            }
        }

        self.titleID = titleID
        self.version = version
        self.taggedKind = taggedKind
        self.summary = summary
        title = SwitchFileInfo.cleanTitle(stem)
    }

    /// Text before the first `[` or `(`, trimmed.
    static func cleanTitle(_ stem: String) -> String {
        let cut = stem.firstIndex { $0 == "[" || $0 == "(" } ?? stem.endIndex
        let title = stem[..<cut].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_")))
        return title.isEmpty ? stem : title
    }

    static func bracketedTags(in string: String) -> [String] {
        var tags: [String] = []
        var current: String?
        for character in string {
            if character == "[" {
                current = ""
            } else if character == "]" {
                if let tag = current { tags.append(tag.trimmingCharacters(in: .whitespaces)) }
                current = nil
            } else {
                current?.append(character)
            }
        }
        return tags
    }

    /// Parses `B`, `B+U393216`, `U65536+3DLC`, `1DLC`, …
    static func parseSummary(_ tag: String) -> DBISummary? {
        var summary = DBISummary(hasBase: false, updateVersion: nil, dlcCount: 0)
        let parts = tag.split(separator: "+")
        guard !parts.isEmpty else { return nil }
        for part in parts {
            if part == "B" {
                summary.hasBase = true
            } else if part.hasPrefix("U"), let v = UInt32(part.dropFirst()) {
                summary.updateVersion = v
            } else if part.hasSuffix("DLC"), let n = Int(part.dropLast(3)) {
                summary.dlcCount = n
            } else {
                return nil
            }
        }
        return summary
    }

    /// Normalized form of a title for fuzzy matching ("SUPER MARIO ODYSSEY" ≈ "Super Mario Odyssey™").
    static func normalize(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}

/// Reads title metadata out of a local NSP/NSZ (PFS0) without needing any keys:
/// tickets are named after the rights ID (title ID + key generation), and some
/// dumps include a plaintext `.cnmt.xml` with the exact type and version.
enum NSPInspector {
    struct Result: Sendable {
        var titleID: TitleID?
        var version: UInt32?
        var kind: TitleID.Kind?
    }

    static func inspect(_ url: URL) -> Result? {
        guard ["nsp", "nsz"].contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 16), header.count == 16,
              header.prefix(4) == Data("PFS0".utf8)
        else { return nil }
        let fileCount = Int(header.uint32(at: 4))
        let stringTableSize = Int(header.uint32(at: 8))
        guard fileCount > 0, fileCount < 4096, stringTableSize < 1 << 20,
              let table = try? handle.read(upToCount: fileCount * 24 + stringTableSize),
              table.count == fileCount * 24 + stringTableSize
        else { return nil }

        let dataStart = UInt64(16 + fileCount * 24 + stringTableSize)
        let strings = table.subdata(in: fileCount * 24..<table.count)
        var result = Result()

        for index in 0..<fileCount {
            let entry = table.subdata(in: index * 24..<(index + 1) * 24)
            let offset = entry.uint64(at: 0)
            let size = entry.uint64(at: 8)
            let nameOffset = Int(entry.uint32(at: 16))
            guard nameOffset < strings.count else { continue }
            let nameBytes = strings[nameOffset...].prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self)

            if name.hasSuffix(".tik"), result.titleID == nil, let id = TitleID(hex: name.prefix(16)) {
                result.titleID = id
            } else if name.hasSuffix(".cnmt.xml"), size < 1 << 20 {
                try? handle.seek(toOffset: dataStart + offset)
                if let xml = try? handle.read(upToCount: Int(size)) {
                    parseCNMT(String(decoding: xml, as: UTF8.self), into: &result)
                }
            }
        }
        if result.kind == nil { result.kind = result.titleID?.kind }
        return result.titleID == nil ? nil : result
    }

    private static func parseCNMT(_ xml: String, into result: inout Result) {
        func value(_ tag: String) -> String? {
            guard let open = xml.range(of: "<\(tag)>"), let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else { return nil }
            return String(xml[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let id = value("Id"), let parsed = TitleID(hex: id.hasPrefix("0x") ? String(id.dropFirst(2)) : id) {
            result.titleID = parsed
        }
        if let version = value("Version").flatMap({ UInt32($0) }) {
            result.version = version
        }
        switch value("Type") {
        case "Application": result.kind = .application
        case "Patch": result.kind = .update
        case "AddOnContent": result.kind = .addOn
        default: break
        }
    }
}

private extension Data {
    func uint32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) }
    }

    func uint64(at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + offset + $1]) << (8 * $1) }
    }
}
