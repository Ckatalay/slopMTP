import MTPKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            if let connection = model.connection {
                BrowserView(connection: connection)
                    .id(ObjectIdentifier(connection))
            } else {
                EmptyStateView()
            }
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.connectingDeviceID != nil {
            ProgressView("Connecting…")
        } else if model.devices.isEmpty {
            ContentUnavailableView {
                Label("No Device Connected", systemImage: "cable.connector")
            } description: {
                Text("Connect your Switch over USB and start an MTP responder on it, such as DBI (“Run MTP responder”) or Sphaira (enable MTP in settings).")
            }
        } else {
            ContentUnavailableView {
                Label("Choose a Device", systemImage: "externaldrive.connected.to.line.below")
            } description: {
                Text("Select a device in the sidebar to browse it.")
            }
        }
    }
}
