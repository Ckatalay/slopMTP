import Foundation
import MTPKit
import Observation

/// Top-level state: attached devices and the active connection.
@MainActor
@Observable
final class AppModel {
    private(set) var devices: [USBMTPDevice] = []
    private(set) var connection: DeviceConnection?
    private(set) var connectingDeviceID: UInt64?
    var alert: AlertItem?

    @ObservationIgnored private let watcher = USBDeviceWatcher()
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        watcher.onChange = { [weak self] devices in
            self?.devicesChanged(devices)
        }
        watcher.start()
    }

    private func devicesChanged(_ devices: [USBMTPDevice]) {
        self.devices = devices
        if let connection, !devices.contains(where: { $0.id == connection.device.id }) {
            connection.markDisconnected()
            self.connection = nil
        } else if connection == nil, connectingDeviceID == nil, devices.count == 1, let only = devices.first, only.isNintendoSwitch {
            // Convenience: connect automatically when a single Switch shows up.
            Task { await connect(only) }
        }
    }

    func connect(_ device: USBMTPDevice) async {
        guard connectingDeviceID == nil else { return }
        if connection?.device.id == device.id { return }
        await disconnect()

        connectingDeviceID = device.id
        defer { connectingDeviceID = nil }
        do {
            let connection = try await DeviceConnection.open(device)
            connection.onError = { [weak self] title, error in
                self?.alert = AlertItem(title: title, message: error.localizedDescription)
            }
            self.connection = connection
            await connection.loadStorages()
        } catch {
            alert = AlertItem(title: "Couldn't connect to \(device.displayName)", message: error.localizedDescription)
        }
    }

    func disconnect() async {
        guard let connection else { return }
        self.connection = nil
        await connection.close()
    }
}

struct AlertItem: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}
