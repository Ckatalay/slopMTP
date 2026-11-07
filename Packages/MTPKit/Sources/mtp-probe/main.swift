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

    let args = CommandLine.arguments
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
