import Foundation
import MTPKit

enum Format {
    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "—"
    }

    static func symbol(for object: MTPObject) -> String {
        if object.isFolder { return "folder.fill" }
        switch (object.name as NSString).pathExtension.lowercased() {
        case "nsp", "nsz", "xci", "xcz": return "gamecontroller"
        case "jpg", "jpeg", "png", "bmp", "gif", "webp": return "photo"
        case "mp4", "mov", "webm": return "film"
        case "zip", "7z", "rar", "tar", "gz": return "doc.zipper"
        case "txt", "log", "ini", "json", "cfg", "xml": return "doc.text"
        case "nro", "nso", "kip", "bin": return "cpu"
        case "sav", "dat": return "externaldrive"
        default: return "doc"
        }
    }
}
