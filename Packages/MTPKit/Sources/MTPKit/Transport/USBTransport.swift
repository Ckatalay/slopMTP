import Foundation
import IOKit
@preconcurrency import IOUSBHost

/// MTP transport over a USB interface (PTP "Still Image" class or vendor-specific MTP),
/// built on the IOUSBHost user-space framework.
public final class USBTransport: MTPTransport, @unchecked Sendable {
    public let maxPacketSize: Int
    public let interfaceNumber: UInt8

    private let lock = NSLock()
    private var interface: IOUSBHostInterface?
    private var bulkIn: IOUSBHostPipe?
    private var bulkOut: IOUSBHostPipe?
    private var interruptIn: IOUSBHostPipe?
    private var terminated = false
    private var interruptPacketSize = 64
    private var eventsActive = false

    /// Opens the IOUSBHostInterface with the given registry entry ID.
    ///
    /// macOS's camera daemon `ptpcamerad` claims every PTP/MTP interface as soon as it appears.
    /// See `openInterface(_:interestHandler:)` for how the interface is taken over.
    public convenience init(registryEntryID: UInt64) throws {
        guard let matching = IORegistryEntryIDMatching(registryEntryID) else {
            throw MTPError.deviceNotFound
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { throw MTPError.deviceNotFound }
        defer { IOObjectRelease(service) }
        try self.init(service: service)
    }

    public init(service: io_service_t) throws {
        let box = TerminationBox()
        let handler: IOUSBHostInterestHandler = { _, messageType, _ in
            if messageType == kIOMessageServiceIsTerminated {
                box.transport?.markTerminated()
            }
        }

        let opened = try USBTransport.openInterface(service, interestHandler: handler)

        var foundIn: UInt8?
        var foundOut: UInt8?
        var foundInterrupt: UInt8?
        var packetSize = 512

        let configuration = opened.configurationDescriptor
        let interfaceDescriptor = opened.interfaceDescriptor
        var endpoint: UnsafePointer<IOUSBEndpointDescriptor>?
        repeat {
            endpoint = IOUSBGetNextEndpointDescriptor(
                configuration, interfaceDescriptor,
                UnsafePointer<IOUSBDescriptorHeader>(OpaquePointer(endpoint))
            )
            guard let ep = endpoint?.pointee else { continue }
            let address = ep.bEndpointAddress
            let isIn = address & 0x80 != 0
            switch ep.bmAttributes & 0x03 {
            case 0x02 where isIn && foundIn == nil:
                foundIn = address
                packetSize = Int(UInt16(littleEndian: ep.wMaxPacketSize) & 0x07FF)
            case 0x02 where !isIn && foundOut == nil:
                foundOut = address
            case 0x03 where isIn && foundInterrupt == nil:
                foundInterrupt = address
                interruptPacketSize = max(Int(UInt16(littleEndian: ep.wMaxPacketSize) & 0x07FF), 8)
            default:
                break
            }
        } while endpoint != nil

        guard let inAddress = foundIn, let outAddress = foundOut else {
            opened.destroy()
            throw MTPError.usb("The interface has no bulk IN/OUT endpoint pair.")
        }

        do {
            bulkIn = try opened.copyPipe(withAddress: Int(inAddress))
            bulkOut = try opened.copyPipe(withAddress: Int(outAddress))
            if let interruptAddress = foundInterrupt {
                interruptIn = try? opened.copyPipe(withAddress: Int(interruptAddress))
            }
        } catch let error as NSError {
            opened.destroy()
            throw USBTransport.translate(error)
        }

        interface = opened
        interfaceNumber = interfaceDescriptor.pointee.bInterfaceNumber
        maxPacketSize = max(packetSize, 64)
        box.transport = self
    }

    deinit {
        close()
    }

    // MARK: - MTPTransport

    public func write(_ data: Data, timeout: TimeInterval) throws {
        let pipe = try pipe(\.bulkOut)
        let buffer: NSMutableData? = data.isEmpty ? nil : NSMutableData(data: data)
        var transferred = 0
        do {
            try pipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch let error as NSError {
            throw recover(from: error, pipe: pipe)
        }
        guard transferred == data.count else {
            throw MTPError.usb("Short write: \(transferred) of \(data.count) bytes")
        }
    }

    public func read(maxLength: Int, timeout: TimeInterval) throws -> Data {
        let pipe = try pipe(\.bulkIn)
        guard let buffer = NSMutableData(length: maxLength) else {
            throw MTPError.usb("Could not allocate a \(maxLength)-byte buffer")
        }
        var transferred = 0
        do {
            try pipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch let error as NSError {
            throw recover(from: error, pipe: pipe)
        }
        return Data(bytes: buffer.bytes, count: transferred)
    }

    public func cancelTransaction(_ transactionID: UInt32) throws {
        lock.lock()
        let interface = self.interface
        let pipes = [bulkIn, bulkOut].compactMap { $0 }
        lock.unlock()
        guard let interface else { throw MTPError.disconnected }

        // PIMA 15740 USB still image class "Cancel Request" (bRequest 0x64):
        // 6 bytes of data — cancellation code 0x4001 followed by the transaction ID.
        var payload = PTPDataWriter()
        payload.write(UInt16(0x4001))
        payload.write(transactionID)
        let request = IOUSBDeviceRequest(
            bmRequestType: 0x21, // host-to-device | class | interface
            bRequest: 0x64,
            wValue: 0,
            wIndex: UInt16(interfaceNumber),
            wLength: UInt16(payload.data.count)
        )
        var transferred = 0
        try? interface.__send(request, data: NSMutableData(data: payload.data), bytesTransferred: &transferred, completionTimeout: 5)

        for pipe in pipes {
            try? pipe.__abort(with: .synchronous)
            try? pipe.clearStall()
        }

        // Poll "Get Device Status" (bRequest 0x67) until the device reports OK (0x2001).
        let statusRequest = IOUSBDeviceRequest(
            bmRequestType: 0xA1, // device-to-host | class | interface
            bRequest: 0x67,
            wValue: 0,
            wIndex: UInt16(interfaceNumber),
            wLength: 20
        )
        for _ in 0..<20 {
            guard let buffer = NSMutableData(length: 20) else { break }
            var count = 0
            guard (try? interface.__send(statusRequest, data: buffer, bytesTransferred: &count, completionTimeout: 2)) != nil,
                  count >= 4
            else { break }
            var reader = PTPDataReader(Data(bytes: buffer.bytes, count: count))
            _ = try? reader.read(UInt16.self)
            let code: UInt16 = (try? reader.read()) ?? 0
            if code == ResponseCode.ok.rawValue { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: - Events

    public func startEventStream(_ handler: @escaping @Sendable (Data) -> Void) -> Bool {
        lock.lock()
        guard let pipe = interruptIn, !terminated, !eventsActive else {
            lock.unlock()
            return false
        }
        eventsActive = true
        lock.unlock()
        armEventRead(on: pipe, handler: handler)
        return true
    }

    public func stopEventStream() {
        lock.lock()
        let pipe = eventsActive ? interruptIn : nil
        eventsActive = false
        lock.unlock()
        try? pipe?.__abort(with: .asynchronous)
    }

    /// Queues one asynchronous interrupt read; the completion handler re-arms it.
    /// Runs on IOUSBHost's own queue, so it never contends with the session's bulk transfers.
    private func armEventRead(on pipe: IOUSBHostPipe, handler: @escaping @Sendable (Data) -> Void) {
        guard let data = NSMutableData(length: interruptPacketSize * 2) else { return }
        // IOUSBHost owns the buffer until the completion handler runs.
        let buffer = UncheckedBox(data)
        do {
            try pipe.enqueueIORequest(with: data, completionTimeout: 0) { [weak self] status, transferred in
                guard let self else { return }
                if status == 0, transferred > 0 {
                    handler(Data(bytes: buffer.value.bytes, count: transferred))
                }
                self.lock.lock()
                let keepGoing = self.eventsActive && !self.terminated && self.interruptIn === pipe
                self.lock.unlock()
                guard keepGoing else { return }
                switch status {
                case 0:
                    self.armEventRead(on: pipe, handler: handler)
                case kIOUSBPipeStalledValue:
                    try? pipe.clearStall()
                    self.armEventRead(on: pipe, handler: handler)
                default:
                    // Aborted, device gone or an unexpected error: stop listening.
                    self.lock.lock()
                    self.eventsActive = false
                    self.lock.unlock()
                }
            }
        } catch {
            lock.lock()
            eventsActive = false
            lock.unlock()
        }
    }

    public func close() {
        lock.lock()
        eventsActive = false
        let interface = self.interface
        let pipes = [bulkIn, bulkOut, interruptIn].compactMap { $0 }
        self.interface = nil
        bulkIn = nil
        bulkOut = nil
        interruptIn = nil
        lock.unlock()

        for pipe in pipes { try? pipe.__abort(with: .synchronous) }
        interface?.destroy()
    }

    // MARK: - Helpers

    private func markTerminated() {
        lock.lock()
        terminated = true
        lock.unlock()
    }

    private func pipe(_ keyPath: KeyPath<USBTransport, IOUSBHostPipe?>) throws -> IOUSBHostPipe {
        lock.lock()
        defer { lock.unlock() }
        guard !terminated, let pipe = self[keyPath: keyPath] else { throw MTPError.disconnected }
        return pipe
    }

    private func recover(from error: NSError, pipe: IOUSBHostPipe) -> MTPError {
        let translated = USBTransport.translate(error)
        if USBTransport.ioReturn(of: error) == kIOUSBPipeStalledValue {
            try? pipe.clearStall()
        }
        lock.lock()
        let isTerminated = terminated
        lock.unlock()
        return isTerminated ? .disconnected : translated
    }

    /// Opens the interface, taking it over from `ptpcamerad` if necessary:
    /// 1. a plain open;
    /// 2. an open with `.deviceSeize`, which asks the current owner to close;
    /// 3. if the owner is `ptpcamerad` (a per-user launch agent that launchd restarts on demand),
    ///    terminate it and open the interface in the window before it respawns and re-claims it.
    private static func openInterface(_ service: io_service_t, interestHandler: @escaping IOUSBHostInterestHandler) throws -> IOUSBHostInterface {
        func attempt(_ options: IOUSBHostObjectInitOptions) throws -> IOUSBHostInterface {
            try IOUSBHostInterface(__ioService: service, options: options, queue: nil, interestHandler: interestHandler)
        }

        let firstError: NSError
        do {
            return try attempt([])
        } catch let error as NSError {
            firstError = error
        }
        if let interface = try? attempt([.deviceSeize]) {
            return interface
        }

        guard let owner = exclusiveOwner(of: service) else {
            throw translate(firstError)
        }
        guard owner.name == "ptpcamerad", owner.pid > 0 else {
            throw MTPError.interfaceBusy(owner: owner.name)
        }

        kill(owner.pid, SIGKILL)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let interface = try? attempt([]) {
                return interface
            }
            usleep(20_000)
        }
        throw MTPError.interfaceBusy(owner: owner.name)
    }

    /// Parses the registry's `UsbExclusiveOwner` property, e.g. `"pid 24197, ptpcamerad"`.
    static func exclusiveOwner(of service: io_service_t) -> (pid: pid_t, name: String)? {
        guard let value = IORegistryEntryCreateCFProperty(service, "UsbExclusiveOwner" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        else { return nil }
        return parseExclusiveOwner(value)
    }

    static func parseExclusiveOwner(_ value: String) -> (pid: pid_t, name: String)? {
        let parts = value.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts[0].hasPrefix("pid "), let pid = pid_t(parts[0].dropFirst(4)) else { return nil }
        return (pid, parts[1])
    }

    static func ioReturn(of error: NSError) -> Int32 {
        Int32(truncatingIfNeeded: error.code)
    }

    static func translate(_ error: NSError) -> MTPError {
        switch ioReturn(of: error) {
        case kIOReturnExclusiveAccessValue: return .interfaceBusy(owner: nil)
        case kIOReturnTimeoutValue: return .timeout
        case kIOReturnNoDeviceValue, kIOReturnNotAttachedValue, kIOReturnNotRespondingValue: return .disconnected
        case kIOReturnAbortedValue: return .cancelled
        default:
            return .usb(String(format: "%@ (0x%08X)", error.localizedDescription, UInt32(bitPattern: ioReturn(of: error))))
        }
    }
}

private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private final class TerminationBox: @unchecked Sendable {
    weak var transport: USBTransport?
}

// IOReturn values (the C macros are not imported into Swift).
let kIOReturnExclusiveAccessValue = Int32(bitPattern: 0xE000_02C5)
let kIOReturnTimeoutValue = Int32(bitPattern: 0xE000_02D6)
let kIOReturnNoDeviceValue = Int32(bitPattern: 0xE000_02C0)
let kIOReturnNotAttachedValue = Int32(bitPattern: 0xE000_02DD)
let kIOReturnNotRespondingValue = Int32(bitPattern: 0xE000_02ED)
let kIOReturnAbortedValue = Int32(bitPattern: 0xE000_02EB)
let kIOUSBPipeStalledValue = Int32(bitPattern: 0xE000_404F)
let kIOMessageServiceIsTerminated: UInt32 = 0xE000_0010
