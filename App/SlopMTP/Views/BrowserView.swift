import MTPKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @Bindable var connection: DeviceConnection
    @State private var sortOrder = [KeyPathComparator(\MTPObject.name, comparator: .localizedStandard)]
    @State private var newFolderName = ""
    @State private var renameText = ""
    @State private var isDropTargeted = false
    @State private var isShowingInfo = false

    private var sortedItems: [MTPObject] {
        let sorted = connection.items.sorted(using: sortOrder)
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    var body: some View {
        fileTable
            .softVerticalEdges()
            .edgeBar(.top) {
                PathBar(connection: connection)
            }
            .edgeBar(.bottom) {
                if !connection.transfers.transfers.isEmpty {
                    TransfersPanel(queue: connection.transfers)
                        .padding(10)
                }
            }
        .navigationTitle(connection.path.last?.name ?? connection.selectedStorage?.info.displayName ?? connection.displayName)
        .navigationSubtitle(connection.displayName)
        .toolbar { toolbar }
        .alert("New Folder", isPresented: $connection.isShowingNewFolderPrompt) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await connection.createFolder(named: name) }
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Rename", isPresented: renameBinding, presenting: connection.renameTarget) { target in
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText
                Task { await connection.rename(target, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let objects = connection.pendingDeletion
                connection.pendingDeletion = []
                Task { await connection.delete(objects) }
            }
        } message: {
            Text("This permanently deletes the items from the device.")
        }
    }

    // MARK: - Table

    private var fileTable: some View {
        Table(sortedItems, selection: $connection.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                Label {
                    Text(item.name).lineLimit(1)
                } icon: {
                    Image(systemName: Format.symbol(for: item))
                        .foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
                }
            }
            TableColumn("Size", value: \.size) { item in
                Text(item.isFolder ? "—" : Format.bytes(item.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90, max: 120)
            TableColumn("Modified", value: \.sortDate) { item in
                Text(item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160, max: 220)
        }
        .contextMenu(forSelectionType: UInt32.self) { handles in
            contextMenu(for: handles)
        } primaryAction: { handles in
            guard handles.count == 1, let item = connection.items.first(where: { handles.contains($0.handle) }) else { return }
            if item.isFolder {
                Task { await connection.open(item) }
            } else {
                connection.chooseDownloadDestination(for: [item])
            }
        }
        .overlay {
            if connection.isLoading && connection.items.isEmpty {
                // MTP runs one operation at a time, so listings queue behind transfers.
                ProgressView(connection.transfers.hasActiveTransfers ? "Waiting for the current transfer to finish…" : "Loading…")
            } else if connection.isDisconnected {
                ContentUnavailableView("Device Disconnected", systemImage: "cable.connector.slash")
            } else if connection.items.isEmpty && !connection.isLoading {
                ContentUnavailableView {
                    Label("Empty Folder", systemImage: "folder")
                } description: {
                    if connection.canModify {
                        Text("Drop files here to upload them.")
                    }
                }
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard connection.canModify, !files.isEmpty else { return false }
            connection.upload(files)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted && connection.canModify
        }
        .onKeyPress(.delete) {
            requestDelete(connection.selectedItems)
            return .handled
        }
    }

    @ViewBuilder
    private func contextMenu(for handles: Set<UInt32>) -> some View {
        let objects = connection.items.filter { handles.contains($0.handle) }
        if !objects.isEmpty {
            if objects.count == 1, let folder = objects.first, folder.isFolder {
                Button("Open") { Task { await connection.open(folder) } }
                Divider()
            }
            Button("Download…") { connection.chooseDownloadDestination(for: objects) }
            if connection.canModify {
                if objects.count == 1, let object = objects.first {
                    Button("Rename…") {
                        renameText = object.name
                        connection.renameTarget = object
                    }
                    .disabled(!connection.deviceInfo.supports(.setObjectPropValue))
                }
                Divider()
                Button("Delete…", role: .destructive) { requestDelete(objects) }
            }
        } else if connection.canModify {
            Button("New Folder…") { connection.requestNewFolder() }
            Button("Upload…") { connection.chooseFilesToUpload() }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await connection.goUp() }
            } label: {
                Label("Enclosing Folder", systemImage: "chevron.up")
            }
            .disabled(connection.path.isEmpty)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("Go to the enclosing folder")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                connection.requestNewFolder()
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(!connection.canModify)
            .help("New folder")

            Button {
                connection.chooseFilesToUpload()
            } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            }
            .disabled(!connection.canModify)
            .help("Upload files or folders to this folder")

            Button {
                connection.chooseDownloadDestination(for: connection.selectedItems)
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .disabled(connection.selection.isEmpty)
            .help("Download the selected items")

            Button(role: .destructive) {
                requestDelete(connection.selectedItems)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(connection.selection.isEmpty || !connection.canModify)
            .help("Delete the selected items")

            Button {
                Task { await connection.reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh")

            Button {
                isShowingInfo.toggle()
            } label: {
                Label("Device Info", systemImage: "info.circle")
            }
            .help("Device information")
            .popover(isPresented: $isShowingInfo, arrowEdge: .bottom) {
                DeviceInfoView(connection: connection)
            }
        }
    }

    // MARK: - Helpers

    private func requestDelete(_ objects: [MTPObject]) {
        guard connection.canModify, !objects.isEmpty else { return }
        connection.pendingDeletion = objects
    }

    private var deleteTitle: String {
        let objects = connection.pendingDeletion
        return objects.count == 1 ? "Delete “\(objects[0].name)”?" : "Delete \(objects.count) items?"
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { !connection.pendingDeletion.isEmpty }, set: { if !$0 { connection.pendingDeletion = [] } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { connection.renameTarget != nil }, set: { if !$0 { connection.renameTarget = nil } })
    }
}

private struct PathBar: View {
    let connection: DeviceConnection

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    crumb(connection.selectedStorage?.info.displayName ?? "Storage", systemImage: "sdcard", entry: nil)
                    ForEach(connection.path, id: \.self) { entry in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        crumb(entry.name, systemImage: "folder", entry: entry)
                    }
                }
                .padding(.vertical, 7)
            }
            if connection.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading")
            }
        }
        .padding(.horizontal, 12)
        .glassPanel(cornerRadius: 20)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    private func crumb(_ title: String, systemImage: String, entry: DeviceConnection.PathEntry?) -> some View {
        Button {
            Task { await connection.goTo(entry) }
        } label: {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .disabled(entry == connection.path.last)
    }
}

private struct DeviceInfoView: View {
    let connection: DeviceConnection

    var body: some View {
        let info = connection.deviceInfo
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Manufacturer", info.manufacturer)
            row("Model", info.model)
            row("Version", info.deviceVersion)
            row("Serial", info.serialNumber)
            row("USB ID", String(format: "%04X:%04X", connection.device.vendorID, connection.device.productID))
            row("Extension", info.vendorExtensionDescription)
            row("Operations", "\(info.operationsSupported.count) supported")
            row("Large uploads", info.supports(.sendObjectPropList) ? "SendObjectPropList (64-bit)" : "SendObjectInfo")
        }
        .textSelection(.enabled)
        .padding()
        .frame(minWidth: 320)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
        }
    }
}

extension MTPObject {
    var sortDate: Date { modified ?? .distantPast }
}
