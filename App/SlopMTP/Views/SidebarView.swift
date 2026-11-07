import MTPKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: storageSelection) {
            Section("Devices") {
                if model.devices.isEmpty {
                    Text("Waiting for a device…")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    DeviceRow(device: device)
                }
            }

            if let connection = model.connection {
                if connection.dbiLayout != nil {
                    Section("Switch") {
                        Label("Game Library", systemImage: "square.grid.2x2.fill")
                            .tag(DeviceConnection.SidebarItem.library)
                        if connection.dbiLayout?.album != nil {
                            Label("Album", systemImage: "photo.on.rectangle.angled")
                                .tag(DeviceConnection.SidebarItem.album)
                        }
                    }
                }
                Section(connection.dbiLayout != nil ? "Storage" : connection.displayName) {
                    ForEach(connection.storages) { storage in
                        StorageRow(storage: storage)
                            .tag(DeviceConnection.SidebarItem.storage(storage.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var storageSelection: Binding<DeviceConnection.SidebarItem?> {
        Binding(
            get: { model.connection?.sidebarSelection },
            set: { item in
                guard let connection = model.connection else { return }
                Task { await connection.select(item) }
            }
        )
    }
}

private struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: USBMTPDevice

    private var isConnected: Bool { model.connection?.device.id == device.id }
    private var isConnecting: Bool { model.connectingDeviceID == device.id }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.isNintendoSwitch ? "gamecontroller.fill" : "externaldrive.fill")
                .foregroundStyle(device.isNintendoSwitch ? .red : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                    .lineLimit(1)
                Text(String(format: "%04X:%04X", device.vendorID, device.productID) + (device.interfaceName.isEmpty ? "" : " · \(device.interfaceName)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isConnecting {
                ProgressView().controlSize(.small)
            } else if isConnected {
                Button {
                    Task { await model.disconnect() }
                } label: {
                    Image(systemName: "eject.fill")
                }
                .buttonStyle(.borderless)
                .help("Disconnect")
                .accessibilityLabel("Disconnect \(device.displayName)")
            } else {
                Button("Connect") {
                    Task { await model.connect(device) }
                }
                .buttonStyle(.borderless)
                .disabled(model.connectingDeviceID != nil)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct StorageRow: View {
    let storage: MTPStorage

    var body: some View {
        let info = storage.info
        VStack(alignment: .leading, spacing: 4) {
            Label(info.displayName, systemImage: info.isReadOnly ? "lock.fill" : "sdcard.fill")
                .lineLimit(1)
            if info.maxCapacity > 0 {
                let used = info.maxCapacity - min(info.freeSpaceInBytes, info.maxCapacity)
                ProgressView(value: Double(used), total: Double(info.maxCapacity))
                    .controlSize(.small)
                Text("\(Format.bytes(info.freeSpaceInBytes)) free of \(Format.bytes(info.maxCapacity))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
