import Foundation

public enum MTPError: Error, LocalizedError, Equatable, Sendable {
    case deviceNotFound
    /// Another process holds the USB interface. `owner` is its name when known.
    case interfaceBusy(owner: String?)
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
            return L("The MTP device could not be found. Is it still connected?", comment: "Error")
        case .interfaceBusy(let owner?):
            return L("The device's MTP interface is in use by “\(owner)”. Quit it and try again.", comment: "Error. The placeholder is the name of the app or process using the device.")
        case .interfaceBusy(nil):
            return L("The device's MTP interface is in use by another process. Quit Image Capture, Photos, Android File Transfer or OpenMTP and try again.", comment: "Error. App names are not translated.")
        case .usb(let message):
            return L("USB error: \(message)", comment: "Error. The placeholder is a technical message.")
        case .timeout:
            return L("The device did not respond in time.", comment: "Error")
        case .disconnected:
            return L("The device was disconnected.", comment: "Error")
        case .malformedData(let message):
            return L("The device sent malformed data: \(message)", comment: "Error. The placeholder is a technical message.")
        case .unexpectedContainer(let message):
            return L("Protocol error: \(message)", comment: "Error. The placeholder is a technical message.")
        case .transactionMismatch(let expected, let received):
            return L("Protocol error: expected transaction \(expected), got \(received).", comment: "Error with two transaction numbers")
        case .response(let code, let operation):
            return L("\(operation.description) failed: \(code.localizedDescription).", comment: "Error. The first placeholder is an MTP operation name such as SendObject (not translated), the second the device's reason.")
        case .sessionNotOpen:
            return L("No MTP session is open.", comment: "Error")
        case .operationNotSupported(let operation):
            return L("The device does not support \(operation.description).", comment: "Error. The placeholder is an MTP operation name such as SendObject (not translated).")
        case .cancelled:
            return L("The operation was cancelled.", comment: "Error")
        case .localFile(let message):
            return message
        }
    }
}

/// Localized text from MTPKit's own string catalog.
func L(_ value: String.LocalizationValue, comment: StaticString) -> String {
    String(localized: value, bundle: .module, comment: comment)
}
