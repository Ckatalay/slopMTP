import Foundation

public enum MTPError: Error, LocalizedError, Equatable, Sendable {
    case deviceNotFound
    /// Another process (usually macOS's `ptpcamerad`) holds the USB interface.
    case interfaceBusy
    case usb(String)
    case timeout
    case disconnected
    case malformedData(String)
    case unexpectedContainer(String)
    case transactionMismatch(expected: UInt32, received: UInt32)
    case response(ResponseCode, operation: OperationCode)
    case sessionNotOpen
    case operationNotSupported(OperationCode)
    case cancelled
    case localFile(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "The MTP device could not be found. Is it still connected?"
        case .interfaceBusy:
            return "The device's MTP interface is in use by another process. Quit Image Capture, Photos, Android File Transfer or OpenMTP and try again."
        case .usb(let message):
            return "USB error: \(message)"
        case .timeout:
            return "The device did not respond in time."
        case .disconnected:
            return "The device was disconnected."
        case .malformedData(let message):
            return "The device sent malformed data: \(message)"
        case .unexpectedContainer(let message):
            return "Protocol error: \(message)"
        case .transactionMismatch(let expected, let received):
            return "Protocol error: expected transaction \(expected), got \(received)."
        case .response(let code, let operation):
            return "\(operation) failed: \(code)."
        case .sessionNotOpen:
            return "No MTP session is open."
        case .operationNotSupported(let operation):
            return "The device does not support \(operation)."
        case .cancelled:
            return "The operation was cancelled."
        case .localFile(let message):
            return message
        }
    }
}
