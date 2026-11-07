import Foundation
import IOKit
import IOKit.usb

/// An MTP-capable USB interface currently attached to the Mac.
public struct USBMTPDevice: Identifiable, Hashable, Sendable {
    /// Registry entry ID of the IOUSBHostInterface.
    public var id: UInt64
    public var vendorID: UInt16
    public var productID: UInt16
    public var productName: String
    public var manufacturer: String
    public var serialNumber: String
    public var interfaceNumber: UInt8
    public var interfaceName: String

    public static let nintendoVendorID: UInt16 = 0x057E

    public var isNintendoSwitch: Bool { vendorID == Self.nintendoVendorID }

    public var displayName: String {
        if isNintendoSwitch {
            return productName.isEmpty || productName == "Nintendo Switch" ? "Nintendo Switch" : "Nintendo Switch (\(productName))"
        }
        return productName.isEmpty ? String(format: "USB device %04X:%04X", vendorID, productID) : productName
    }
}

/// Watches IOKit for MTP / PTP USB interfaces being attached and removed.
///
/// Callbacks are delivered on the main queue.
@MainActor
public final class USBDeviceWatcher {
    public private(set) var devices: [UInt64: USBMTPDevice] = [:]
    public var onChange: (([USBMTPDevice]) -> Void)?

    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    public init() {}

    public func start() {
        guard port == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        self.port = port

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostInterface"),
            { context, iterator in
                guard let context else { return }
                let watcher = Unmanaged<USBDeviceWatcher>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { watcher.handleAdded(iterator) }
            },
            context, &addedIterator
        )
        handleAdded(addedIterator)

        IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostInterface"),
            { context, iterator in
                guard let context else { return }
                let watcher = Unmanaged<USBDeviceWatcher>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { watcher.handleRemoved(iterator) }
            },
            context, &removedIterator
        )
        handleRemoved(removedIterator)
    }

    public func stop() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    private func handleAdded(_ iterator: io_iterator_t) {
        var changed = false
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            if let device = Self.describe(service) {
                devices[device.id] = device
                changed = true
            }
        }
        if changed { notify() }
    }

    private func handleRemoved(_ iterator: io_iterator_t) {
        var changed = false
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS, devices.removeValue(forKey: id) != nil {
                changed = true
            }
        }
        if changed { notify() }
    }

    private func notify() {
        onChange?(devices.values.sorted { ($0.isNintendoSwitch ? 0 : 1, $0.id) < ($1.isNintendoSwitch ? 0 : 1, $1.id) })
    }

    // MARK: - Registry inspection

    /// Returns a device description if the interface looks like an MTP responder.
    nonisolated static func describe(_ service: io_service_t) -> USBMTPDevice? {
        let interfaceClass = intProperty(service, "bInterfaceClass") ?? 0
        let interfaceSubClass = intProperty(service, "bInterfaceSubClass") ?? 0
        let interfaceProtocol = intProperty(service, "bInterfaceProtocol") ?? 0
        let interfaceName = stringProperty(service, "kUSBString") ?? stringProperty(service, "USB Interface Name") ?? ""

        let isStillImage = interfaceClass == 0x06 && interfaceSubClass == 0x01 && interfaceProtocol == 0x01
        let isVendorMTP = interfaceClass == 0xFF && interfaceName.uppercased().contains("MTP")
        guard isStillImage || isVendorMTP else { return nil }

        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { return nil }

        return USBMTPDevice(
            id: id,
            vendorID: UInt16(truncatingIfNeeded: intProperty(service, "idVendor", searchParents: true) ?? 0),
            productID: UInt16(truncatingIfNeeded: intProperty(service, "idProduct", searchParents: true) ?? 0),
            productName: stringProperty(service, "kUSBProductString", searchParents: true)
                ?? stringProperty(service, "USB Product Name", searchParents: true) ?? "",
            manufacturer: stringProperty(service, "kUSBVendorString", searchParents: true)
                ?? stringProperty(service, "USB Vendor Name", searchParents: true) ?? "",
            serialNumber: stringProperty(service, "kUSBSerialNumberString", searchParents: true)
                ?? stringProperty(service, "USB Serial Number", searchParents: true) ?? "",
            interfaceNumber: UInt8(truncatingIfNeeded: intProperty(service, "bInterfaceNumber") ?? 0),
            interfaceName: interfaceName
        )
    }

    nonisolated private static func property(_ service: io_service_t, _ key: String, searchParents: Bool) -> Any? {
        if searchParents {
            return IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            )
        }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    nonisolated private static func intProperty(_ service: io_service_t, _ key: String, searchParents: Bool = false) -> Int? {
        (property(service, key, searchParents: searchParents) as? NSNumber)?.intValue
    }

    nonisolated private static func stringProperty(_ service: io_service_t, _ key: String, searchParents: Bool = false) -> String? {
        guard let value = property(service, key, searchParents: searchParents) as? String, !value.isEmpty else { return nil }
        return value
    }
}
