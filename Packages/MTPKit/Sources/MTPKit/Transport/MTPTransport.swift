import Foundation

/// A bidirectional, packet-oriented channel to an MTP responder.
///
/// Implementations are blocking. `MTPSession` serializes every call on its own
/// executor, so a transport never sees concurrent calls.
public protocol MTPTransport: AnyObject, Sendable {
    /// Max packet size of the bulk endpoints. Used to decide when a zero-length packet is required.
    var maxPacketSize: Int { get }

    /// Writes one bulk OUT transfer. An empty `data` sends a zero-length packet.
    func write(_ data: Data, timeout: TimeInterval) throws

    /// Reads one bulk IN transfer of at most `maxLength` bytes.
    /// The transfer completes early on a short packet; a zero-length packet yields empty data.
    func read(maxLength: Int, timeout: TimeInterval) throws -> Data

    /// Asks the device to abort the given transaction and resynchronizes the pipes.
    func cancelTransaction(_ transactionID: UInt32) throws

    /// Releases the underlying device. Further calls must fail with `MTPError.disconnected`.
    func close()

    /// Starts delivering raw event containers from the interrupt endpoint, independently of
    /// (and concurrently with) bulk transfers. Returns false if the transport has no event channel.
    func startEventStream(_ handler: @escaping @Sendable (Data) -> Void) -> Bool

    func stopEventStream()
}

extension MTPTransport {
    public func startEventStream(_ handler: @escaping @Sendable (Data) -> Void) -> Bool { false }
    public func stopEventStream() {}
}
