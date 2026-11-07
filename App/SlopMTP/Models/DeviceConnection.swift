import AppKit
import Foundation
import MTPKit
import Observation

/// An open MTP session plus browsing and transfer state for one device.
@MainActor
@Observable
final class DeviceConnection {
    struct PathEntry: Hashable {
        var handle: UInt32
        var name: String
    }

    let device: USBMTPDevice
    let deviceInfo: DeviceInfo
    @ObservationIgnored let session: MTPSession

    private(set) var storages: [MTPStorage] = []
    private(set) var selectedStorageID: UInt32?
    private(set) var path: [PathEntry] = []
    private(set) var items: [MTPObject] = []
    private(set) var isLoading = false
    private(set) var isDisconnected = false
    var selection: Set<UInt32> = []

    let transfers = TransferQueue()
    let library = SwitchLibrary()

    enum SidebarItem: Hashable {
        case library
        case storage(UInt32)
    }

    /// DBI's storage layout, when the device is a Switch running DBI.
    var dbiLayout: DBILayout? { DBILayout(storages: storages) }
    private(set) var showsLibrary = false
    var pendingInstall: [InstallCandidate] = []
    var installTarget: DBILayout.InstallTarget = DBILayout.InstallTarget(rawValue: UserDefaults.standard.string(forKey: "installTarget") ?? "") ?? .sdCard {
        didSet { UserDefaults.standard.set(installTarget.rawValue, forKey: "installTarget") }
    }

    // Prompts driven by the UI.
    var isShowingNewFolderPrompt = false
    var renameTarget: MTPObject?
    var pendingDeletion: [MTPObject] = []

    @ObservationIgnored var onError: ((String, Error) -> Void)?
    @ObservationIgnored private var listingGeneration = 0

    private init(device: USBMTPDevice, deviceInfo: DeviceInfo, session: MTPSession) {
        self.device = device
        self.deviceInfo = deviceInfo
        self.session = session
        transfers.session = session
        transfers.onTransferFinished = { [weak self] transfer in
            self?.transferFinished(transfer)
        }
    }

    static func open(_ device: USBMTPDevice) async throws -> DeviceConnection {
        let transport = try await Task.detached(priority: .userInitiated) {
            try USBTransport(registryEntryID: device.id)
        }.value
        let session = MTPSession(transport: transport)
        do {
            let info = try await session.open()
            return DeviceConnection(device: device, deviceInfo: info, session: session)
        } catch {
            await session.close()
            throw error
        }
    }

    func close() async {
        transfers.cancelAll()
        await session.close()
    }

    func markDisconnected() {
        isDisconnected = true
        transfers.cancelAll()
        Task { await session.close() }
    }

    // MARK: - Derived state

    var selectedStorage: MTPStorage? {
        storages.first { $0.id == selectedStorageID }
    }

    var currentParent: UInt32 {
        path.last?.handle ?? MTPConstants.rootParent
    }

    var canModify: Bool {
        guard let storage = selectedStorage, !isDisconnected else { return false }
        return !storage.info.isReadOnly
    }

    var selectedItems: [MTPObject] {
        items.filter { selection.contains($0.handle) }
    }

    var displayName: String {
        let model = deviceInfo.model.trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? device.displayName : model
    }

    // MARK: - Navigation

    func loadStorages() async {
        do {
            storages = try await session.storages()
            if dbiLayout != nil {
                showsLibrary = true
                Task { await TitleDatabase.shared.loadIfNeeded() }
                await reloadLibrary()
            } else if selectedStorageID == nil || !storages.contains(where: { $0.id == selectedStorageID }) {
                await selectStorage(storages.first?.id)
            }
        } catch {
            report("Couldn't read storages", error)
        }
    }

    var sidebarSelection: SidebarItem? {
        if showsLibrary { return .library }
        return selectedStorageID.map(SidebarItem.storage)
    }

    func select(_ item: SidebarItem?) async {
        switch item {
        case .library:
            showsLibrary = true
        case .storage(let id):
            showsLibrary = false
            await selectStorage(id)
        case nil:
            break
        }
    }

    func selectStorage(_ id: UInt32?) async {
        showsLibrary = false
        guard id != selectedStorageID else { return }
        selectedStorageID = id
        path = []
        await reload()
    }

    func open(_ object: MTPObject) async {
        guard object.isFolder else { return }
        path.append(PathEntry(handle: object.handle, name: object.name))
        await reload()
    }

    func goUp() async {
        guard !path.isEmpty else { return }
        path.removeLast()
        await reload()
    }

    /// Navigates to a breadcrumb. `nil` means the storage root.
    func goTo(_ entry: PathEntry?) async {
        if let entry, let index = path.firstIndex(of: entry) {
            path.removeSubrange((index + 1)...)
        } else {
            path = []
        }
        await reload()
    }

    func reload() async {
        guard let storageID = selectedStorageID, !isDisconnected else {
            items = []
            return
        }
        listingGeneration += 1
        let generation = listingGeneration
        let parent = currentParent
        isLoading = true
        defer { if generation == listingGeneration { isLoading = false } }

        do {
            let contents = try await session.contents(storageID: storageID, parent: parent)
            guard generation == listingGeneration else { return }
            items = contents
            selection = selection.intersection(contents.map(\.handle))
        } catch {
            guard generation == listingGeneration else { return }
            items = []
            report("Couldn't list folder", error)
        }
    }

    // MARK: - Switch library

    func reloadLibrary() async {
        guard let layout = dbiLayout, !isDisconnected else { return }
        await library.reload(session: session, layout: layout)
    }

    func chooseFilesToInstall() {
        let panel = NSOpenPanel()
        panel.title = "Install Games, Updates or DLC"
        panel.prompt = "Review"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK else { return }
        prepareInstall(panel.urls)
    }

    func prepareInstall(_ urls: [URL]) {
        let plan = InstallPlanner.plan(urls, library: library)
        if plan.isEmpty {
            onError?("Nothing to install", MTPError.localFile("No NSP, NSZ, XCI or XCZ files were found in the dropped items."))
        } else {
            pendingInstall = plan
        }
    }

    func startPendingInstall() {
        guard let target = dbiLayout?.storage(for: installTarget) else { return }
        for candidate in pendingInstall where candidate.isSelected {
            transfers.enqueueUpload(candidate.url, storageID: target.id, parent: MTPConstants.rootParent)
        }
        pendingInstall = []
    }

    /// Saves a game's installed contents (or DBI's merged dump) to a folder on the Mac.
    func backUp(_ game: InstalledGame) {
        let objects = game.contents.isEmpty ? [game.mergedDump].compactMap { $0 } : game.contents.map(\.object)
        chooseDownloadDestination(for: objects)
    }

    func showInFiles(_ game: InstalledGame, layout: DBILayout) {
        guard let folder = game.folder else { return }
        Task {
            showsLibrary = false
            selectedStorageID = layout.installedGames.id
            path = [PathEntry(handle: folder.handle, name: folder.name)]
            await reload()
        }
    }

    private func refreshStorageInfo() async {
        if let updated = try? await session.storages() {
            storages = updated
        }
    }

    // MARK: - Actions

    func chooseFilesToUpload() {
        guard canModify else { return }
        let panel = NSOpenPanel()
        panel.title = "Upload to \(path.last?.name ?? selectedStorage?.info.displayName ?? "device")"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        upload(panel.urls)
    }

    func upload(_ urls: [URL]) {
        guard let storageID = selectedStorageID, canModify else { return }
        let parent = currentParent
        for url in urls {
            transfers.enqueueUpload(url, storageID: storageID, parent: parent)
        }
    }

    func chooseDownloadDestination(for objects: [MTPObject]) {
        guard !objects.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Download \(objects.count == 1 ? "“\(objects[0].name)”" : "\(objects.count) items")"
        panel.prompt = "Download Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        for object in objects {
            transfers.enqueueDownload(object, to: directory)
        }
    }

    func requestNewFolder() {
        guard canModify else { return }
        isShowingNewFolderPrompt = true
    }

    func createFolder(named name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let storageID = selectedStorageID else { return }
        do {
            let handle = try await session.createFolder(name: name, storageID: storageID, parent: currentParent)
            await reload()
            selection = [handle]
        } catch {
            report("Couldn't create folder", error)
        }
    }

    func rename(_ object: MTPObject, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != object.name else { return }
        do {
            try await session.rename(object.handle, to: name)
            await reload()
        } catch {
            report("Couldn't rename “\(object.name)”", error)
        }
    }

    func delete(_ objects: [MTPObject]) async {
        for object in objects {
            do {
                try await deleteRecursively(object)
            } catch {
                report("Couldn't delete “\(object.name)”", error)
                break
            }
        }
        await reload()
        await refreshStorageInfo()
    }

    /// Most responders delete folders recursively; fall back to emptying the folder first.
    private func deleteRecursively(_ object: MTPObject) async throws {
        do {
            try await session.delete(object.handle)
        } catch let error as MTPError where object.isFolder {
            guard case .response = error else { throw error }
            let children = try await session.contents(storageID: object.storageID, parent: object.handle)
            for child in children {
                try await deleteRecursively(child)
            }
            try await session.delete(object.handle)
        }
    }

    private func transferFinished(_ transfer: Transfer) {
        if case .failed(let message) = transfer.state {
            onError?("Transfer of “\(transfer.name)” failed", MTPError.localFile(message))
        }
        guard transfer.direction == .upload else { return }
        let isInstall = [dbiLayout?.sdInstall?.id, dbiLayout?.nandInstall?.id].contains(transfer.storageID)
        Task {
            if transfer.parent == currentParent, transfer.storageID == selectedStorageID {
                await reload()
            }
            await refreshStorageInfo()
            if isInstall, transfer.state == .completed, !transfers.hasActiveTransfers {
                await reloadLibrary()
            }
        }
    }

    private func report(_ title: String, _ error: Error) {
        if case MTPError.disconnected = error { isDisconnected = true }
        onError?(title, error)
    }
}
