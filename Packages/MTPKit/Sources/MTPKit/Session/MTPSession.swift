import Foundation

/// Drives PTP/MTP transactions over an `MTPTransport`.
///
/// The actor runs on its own serial dispatch queue, so the blocking USB I/O performed
/// by transactions never occupies the Swift cooperative thread pool. MTP allows only one
/// transaction at a time; actor isolation enforces that.
public actor MTPSession {
    public struct Timeouts: Sendable {
        /// Command and small response transfers.
        public var command: TimeInterval = 10
        /// Each bulk transfer during a data phase.
        public var data: TimeInterval = 30
        /// The response following a large outgoing data phase. Some responders (e.g. installers)
        /// finish processing before answering, so this is generous.
        public var responseAfterData: TimeInterval = 600

        public init() {}
    }

    /// Size of each bulk transfer. A multiple of every USB bulk max packet size (64/512/1024).
    static let transferSize = 1 << 20

    private let executorQueue = DispatchSerialQueue(label: "MTPSession", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executorQueue.asUnownedSerialExecutor()
    }

    let transport: any MTPTransport
    public var timeouts = Timeouts()
    public private(set) var deviceInfo: DeviceInfo?
    public private(set) var sessionID: UInt32?
    private var nextTransactionID: UInt32 = 0

    public init(transport: any MTPTransport) {
        self.transport = transport
    }

    public func setTimeouts(_ timeouts: Timeouts) {
        self.timeouts = timeouts
    }

    // MARK: - Session lifecycle

    /// Fetches DeviceInfo and opens session 1.
    @discardableResult
    public func open() throws -> DeviceInfo {
        let info = try fetchDeviceInfo()
        deviceInfo = info

        let id: UInt32 = 1
        nextTransactionID = 0
        var response = try rawTransaction(.openSession, [id])
        if response.code == .sessionAlreadyOpen {
            // A previous client left a session open. Close it and start over.
            _ = try? rawTransaction(.closeSession)
            nextTransactionID = 0
            response = try rawTransaction(.openSession, [id])
        }
        guard response.code == .ok || response.code == .sessionAlreadyOpen else {
            throw MTPError.response(response.code, operation: .openSession)
        }
        sessionID = id
        return info
    }

    public func close() {
        if sessionID != nil {
            _ = try? rawTransaction(.closeSession)
        }
        sessionID = nil
        transport.close()
    }

    public func fetchDeviceInfo() throws -> DeviceInfo {
        let data = try transactionData(.getDeviceInfo)
        return try DeviceInfo(parsing: data)
    }

    // MARK: - Transaction engine

    enum DataPhase {
        case none
        case outgoing(DataSource)
        case incoming((Data) throws -> Void)
    }

    /// Supplies bytes for an outgoing data phase.
    struct DataSource {
        var length: UInt64
        /// Returns exactly `count` bytes (or fewer only at the end of the stream).
        var read: (Int) throws -> Data

        static func memory(_ data: Data) -> DataSource {
            var offset = 0
            return DataSource(length: UInt64(data.count)) { count in
                let end = min(offset + count, data.count)
                defer { offset = end }
                return data.subdata(in: offset..<end)
            }
        }
    }

    private func takeTransactionID() -> UInt32 {
        let id = nextTransactionID
        nextTransactionID = nextTransactionID &+ 1
        if nextTransactionID == 0 || nextTransactionID == 0xFFFF_FFFF { nextTransactionID = 1 }
        return id
    }

    /// Runs a transaction and returns the response without checking its code.
    func rawTransaction(
        _ operation: OperationCode,
        _ parameters: [UInt32] = [],
        dataPhase: DataPhase = .none,
        responseTimeout: TimeInterval? = nil
    ) throws -> PTPResponse {
        let transactionID = takeTransactionID()
        let command = PTPContainer.encode(type: .command, code: operation.rawValue, transactionID: transactionID, parameters: parameters)
        try transport.write(command, timeout: timeouts.command)

        do {
            switch dataPhase {
            case .none:
                break
            case .outgoing(let source):
                try sendData(operation: operation, transactionID: transactionID, source: source)
            case .incoming(let sink):
                if let early = try receiveData(transactionID: transactionID, sink: sink) {
                    return early
                }
            }
        } catch is CancellationError {
            try? transport.cancelTransaction(transactionID)
            drainAfterCancel()
            throw MTPError.cancelled
        } catch MTPError.cancelled {
            try? transport.cancelTransaction(transactionID)
            drainAfterCancel()
            throw MTPError.cancelled
        }

        return try readResponse(transactionID: transactionID, timeout: responseTimeout ?? timeouts.command)
    }

    /// Runs a transaction and throws unless the device answers OK.
    @discardableResult
    func transaction(
        _ operation: OperationCode,
        _ parameters: [UInt32] = [],
        dataPhase: DataPhase = .none,
        responseTimeout: TimeInterval? = nil
    ) throws -> PTPResponse {
        let response = try rawTransaction(operation, parameters, dataPhase: dataPhase, responseTimeout: responseTimeout)
        guard response.code == .ok else {
            throw MTPError.response(response.code, operation: operation)
        }
        return response
    }

    /// Runs a transaction with an incoming data phase and returns the collected payload.
    func transactionData(_ operation: OperationCode, _ parameters: [UInt32] = []) throws -> Data {
        var collected = Data()
        try transaction(operation, parameters, dataPhase: .incoming { collected.append($0) })
        return collected
    }

    private func sendData(operation: OperationCode, transactionID: UInt32, source: DataSource) throws {
        let total = UInt64(PTPContainerHeader.size) + source.length
        let lengthField = total > UInt64(UInt32.max) ? PTPContainerHeader.unknownLength : UInt32(total)
        let header = PTPContainerHeader(length: lengthField, type: .data, code: operation.rawValue, transactionID: transactionID)

        // The first transfer carries the header plus as much payload as fits, so every transfer
        // except the last is exactly `transferSize` bytes (a multiple of the max packet size).
        var buffer = header.encoded
        let firstCount = Int(min(source.length, UInt64(Self.transferSize - PTPContainerHeader.size)))
        let first = try source.read(firstCount)
        guard first.count == firstCount else { throw MTPError.localFile("The file ended unexpectedly.") }
        buffer.append(first)
        try transport.write(buffer, timeout: timeouts.data)

        var sent = UInt64(firstCount)
        while sent < source.length {
            try Task.checkCancellation()
            let count = Int(min(UInt64(Self.transferSize), source.length - sent))
            let chunk = try source.read(count)
            guard chunk.count == count else { throw MTPError.localFile("The file ended unexpectedly.") }
            try transport.write(chunk, timeout: timeouts.data)
            sent += UInt64(count)
        }

        // A transfer that ends on a packet boundary must be terminated with a zero-length packet.
        if total % UInt64(transport.maxPacketSize) == 0 {
            try transport.write(Data(), timeout: timeouts.data)
        }
    }

    /// Reads a data phase, forwarding payload bytes to `sink`.
    /// Returns a response if the device skipped the data phase and answered immediately.
    private func receiveData(transactionID: UInt32, sink: (Data) throws -> Void) throws -> PTPResponse? {
        var first = Data()
        for _ in 0..<3 where first.isEmpty {
            first = try transport.read(maxLength: Self.transferSize, timeout: timeouts.data)
        }
        let header = try PTPContainerHeader(parsing: first)

        switch header.type {
        case .response:
            return try PTPResponse(parsing: first)
        case .data:
            break
        default:
            throw MTPError.unexpectedContainer("Expected data container, got \(header.type)")
        }
        guard header.transactionID == transactionID else {
            throw MTPError.transactionMismatch(expected: transactionID, received: header.transactionID)
        }

        let payload = first.dropFirst(PTPContainerHeader.size)

        if header.length != PTPContainerHeader.unknownLength {
            var remaining = Int64(header.length) - Int64(PTPContainerHeader.size)
            let firstPayload = payload.prefix(Int(max(0, remaining)))
            if !firstPayload.isEmpty { try sink(Data(firstPayload)) }
            remaining -= Int64(firstPayload.count)

            var emptyReads = 0
            while remaining > 0 {
                try Task.checkCancellation()
                let chunk = try transport.read(maxLength: Self.transferSize, timeout: timeouts.data)
                if chunk.isEmpty {
                    emptyReads += 1
                    if emptyReads > 3 { throw MTPError.malformedData("Data phase ended \(remaining) bytes early") }
                    continue
                }
                let useful = chunk.prefix(Int(min(Int64(chunk.count), remaining)))
                try sink(Data(useful))
                remaining -= Int64(useful.count)
            }
        } else {
            // Length unknown (payload ≥ 4 GiB): read until a transfer ends with a short packet.
            if !payload.isEmpty { try sink(Data(payload)) }
            var lastCount = first.count
            while lastCount == Self.transferSize {
                try Task.checkCancellation()
                let chunk = try transport.read(maxLength: Self.transferSize, timeout: timeouts.data)
                lastCount = chunk.count
                if !chunk.isEmpty { try sink(chunk) }
            }
        }
        return nil
    }

    private func readResponse(transactionID: UInt32, timeout: TimeInterval) throws -> PTPResponse {
        let readSize = max(transport.maxPacketSize, 512)
        for _ in 0..<8 {
            let data = try transport.read(maxLength: readSize, timeout: timeout)
            // Zero-length packets terminate data phases that end on a packet boundary.
            if data.isEmpty { continue }
            let header = try PTPContainerHeader(parsing: data)
            switch header.type {
            case .response:
                let response = try PTPResponse(parsing: data)
                guard response.transactionID == transactionID else {
                    throw MTPError.transactionMismatch(expected: transactionID, received: response.transactionID)
                }
                return response
            case .event:
                continue
            default:
                throw MTPError.unexpectedContainer("Expected response container, got \(header.type)")
            }
        }
        throw MTPError.unexpectedContainer("No response container received")
    }

    /// After a cancel request, discard anything still queued on the IN pipe (including the
    /// "Transaction cancelled" response some devices send).
    private func drainAfterCancel() {
        for _ in 0..<4 {
            guard let data = try? transport.read(maxLength: Self.transferSize, timeout: 0.5), !data.isEmpty else { return }
        }
    }
}
