import Foundation
import IOKit
import MTPKit

// Hardware smoke test: opens the first MTP interface found and prints device info,
// storages and the root folder of each storage.
//
//   swift run mtp-probe [--download <handle> <path>]

func firstMTPInterface() -> USBMTPDevice? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var found: [USBMTPDevice] = []
    while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
        if let device = USBDeviceWatcher.describe(service) { found.append(device) }
        IOObjectRelease(service)
    }
    return found.first { $0.isNintendoSwitch } ?? found.first
}

guard let device = firstMTPInterface() else {
    print("No MTP device found.")
    exit(1)
}
print("Device: \(device.displayName) [\(String(format: "%04X:%04X", device.vendorID, device.productID))] interface \(device.interfaceNumber) “\(device.interfaceName)”")

do {
    let session = MTPSession(transport: try USBTransport(registryEntryID: device.id))
    let info = try await session.open()
    print("Model: \(info.manufacturer) \(info.model) \(info.deviceVersion) serial \(info.serialNumber)")
    print("Extension: \(info.vendorExtensionDescription)")
    print("Operations: " + info.operationsSupported.map(\.description).sorted().joined(separator: ", "))

    let args = CommandLine.arguments
    // --list <storageID hex> [parent handle]: list one folder in full and exit.
    if let i = args.firstIndex(of: "--list"), args.count > i + 1, let storageID = UInt32(args[i + 1], radix: 16) {
        let parent = args.count > i + 2 ? UInt32(args[i + 2]) ?? MTPConstants.rootParent : MTPConstants.rootParent
        for item in try await session.contents(storageID: storageID, parent: parent) {
            print("[\(item.handle)] \(item.isFolder ? "📁" : "  ") \(item.name)  \(item.isFolder ? "" : "\(item.size) B")")
        }
        await session.close()
        exit(0)
    }
    // --cat <handle>: print a small file and exit.
    if let i = args.firstIndex(of: "--cat"), args.count > i + 1, let handle = UInt32(args[i + 1]) {
        print(String(decoding: try await session.data(of: handle), as: UTF8.self))
        await session.close()
        exit(0)
    }

    // --upload <storageID hex> <file>: upload into the storage root and exit.
    if let i = args.firstIndex(of: "--upload"), args.count > i + 2, let storageID = UInt32(args[i + 1], radix: 16) {
        let url = URL(fileURLWithPath: args[i + 2])
        let start = Date()
        let lastPrint = LockedDate()
        do {
            let handle = try await session.upload(url, storageID: storageID) { done, total in
                if lastPrint.shouldPrint() {
                    print(String(format: "  %.1f%%  %llu / %llu  %.1f MB/s", Double(done) / Double(max(total, 1)) * 100, done, total,
                                 Double(done) / Date().timeIntervalSince(start) / 1_000_000))
                }
            }
            print(String(format: "Uploaded as handle %u in %.1fs", handle, Date().timeIntervalSince(start)))
        } catch {
            print(String(format: "Upload failed after %.1fs: %@", Date().timeIntervalSince(start), error.localizedDescription))
        }
        await session.close()
        exit(0)
    }

    for storage in try await session.storages() {
        let s = storage.info
        print(String(format: "\nStorage 0x%08X “%@” free %llu / %llu, access %d", storage.id, s.displayName, s.freeSpaceInBytes, s.maxCapacity, s.accessCapability))
        let start = Date()
        let items = try await session.contents(storageID: storage.id)
        print("  \(items.count) items in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        for item in items.prefix(15) {
            print("  [\(item.handle)] \(item.isFolder ? "📁" : "  ") \(item.name)  \(item.isFolder ? "" : "\(item.size) B")")
        }
    }

    if let i = args.firstIndex(of: "--download"), args.count > i + 2, let handle = UInt32(args[i + 1]) {
        let object = try await session.object(handle)
        let start = Date()
        try await session.download(object, to: URL(fileURLWithPath: args[i + 2]))
        let seconds = Date().timeIntervalSince(start)
        print(String(format: "\nDownloaded %@ (%llu B) in %.2fs — %.1f MB/s", object.name, object.size, seconds, Double(object.size) / seconds / 1_000_000))
    }
    await session.close()
} catch {
    print("Error: \(error.localizedDescription)")
    exit(1)
}

final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func shouldPrint() -> Bool {
        lock.withLock {
            guard Date().timeIntervalSince(last) > 2 else { return false }
            last = Date()
            return true
        }
    }
}
