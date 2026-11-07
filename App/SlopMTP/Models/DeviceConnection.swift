import AppKit
import Foundation
import MTPKit
import Observation
import UniformTypeIdentifiers

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
    /// What each install transfer is, so the library can update the moment it finishes.
    @ObservationIgnored private var installCandidates: [UUID: InstallCandidate] = [:]
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var eventRefresh: Task<Void, Never>?
    @ObservationIgnored private var pendingEventChanges = EventChanges()

    private struct EventChanges {
        var objects = false
        var storages = false
        var isEmpty: Bool { !objects && !storages }
    }
    @ObservationIgnored private var listingGeneration = 0

    private init(device: USBMTPDevice, deviceInfo: DeviceInfo, session: MTPSession) {
        self.device = device
        self.deviceInfo = deviceInfo
        self.session = session
        transfers.session = session
        transfers.onTransferFinished = { [weak self] transfer in
            self?.transferFinished(transfer)
        }
        startListeningForEvents()
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
        stopListeningForEvents()
        transfers.cancelAll()
        await session.close()
    }

    func markDisconnected() {
        isDisconnected = true
        stopListeningForEvents()
        transfers.cancelAll()
        Task { await session.close() }
    }

    // MARK: - Device events

    /// Listens on the interrupt endpoint so the UI follows changes made on the device itself.
    private func startListeningForEvents() {
        let events = session.events()
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    private func stopListeningForEvents() {
        eventTask?.cancel()
        eventTask = nil
        eventRefresh?.cancel()
        eventRefresh = nil
    }

    private func handle(_ event: PTPEvent) {
        switch event.eventCode {
        case .objectAdded, .objectRemoved, .objectInfoChanged, .objectPropChanged:
            pendingEventChanges.objects = true
        case .storeAdded, .storeRemoved, .storageInfoChanged, .storeFull, .deviceInfoChanged:
            pendingEventChanges.storages = true
        default:
            return
        }
        scheduleEventRefresh()
    }

    /// Coalesces bursts of events. While transfers run, the refresh waits for them: listings would
    /// queue behind the transfer anyway, and our own uploads generate events too.
    private func scheduleEventRefresh() {
        eventRefresh?.cancel()
        eventRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, !self.transfers.hasActiveTransfers else { return }
            await self.applyEventChanges()
        }
    }

    private func applyEventChanges() async {
        let changes = pendingEventChanges
        pendingEventChanges = EventChanges()
        guard !changes.isEmpty, !isDisconnected else { return }
        if changes.storages {
            await refreshStorageInfo()
        }
        if changes.objects {
            if showsLibrary {
                await reloadLibrary()
            } else {
                await reload()
            }
        }
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

    /// Reloads the installed-games list. DBI only rebuilds its object tree when a session opens,
    /// so `refreshSession` reopens it first; that invalidates object handles held by the file browser.
    func reloadLibrary(refreshSession: Bool = false) async {
        guard let layout = dbiLayout, !isDisconnected else { return }
        if refreshSession, !transfers.hasActiveTransfers {
            do {
                try await session.reopenSession()
                storages = (try? await session.storages()) ?? storages
                path = []
                items = []
                selection = []
            } catch {
                report("Couldn't refresh the device", error)
                return
            }
        }
        await library.reload(session: session, layout: dbiLayout ?? layout)
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
            let transfer = transfers.enqueueUpload(candidate.url, storageID: target.id, parent: MTPConstants.rootParent)
            installCandidates[transfer.id] = candidate
        }
        pendingInstall = []
    }

    /// Saves a game's installed contents (or DBI's merged dump) to a folder on the Mac.
    func backUp(_ game: InstalledGame) {
        backUp([game]) { game in
            game.applicationID.flatMap { TitleDatabase.shared.entry(for: $0)?.name } ?? game.name
        }
    }

    /// Backs up each game into its own folder, optionally with its save data.
    func backUp(_ games: [InstalledGame], displayName: (InstalledGame) -> String) {
        guard !games.isEmpty else { return }
        let title = games.count == 1 ? "Back Up “\(displayName(games[0]))”" : "Back Up \(games.count) Games"
        guard let (directory, includeSaves) = chooseBackupFolder(title: title, offerSaves: dbiLayout?.saves != nil) else { return }

        var destinations: [(game: InstalledGame, names: [String], folder: URL)] = []
        for game in games {
            let folder = Self.uniqueURL(in: directory, name: Self.sanitize(displayName(game)))
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                report("Couldn't create a folder for “\(displayName(game))”", error)
                return
            }
            let real = game.contents.map(\.object).filter { $0.storageID != 0 }
            for object in real.isEmpty ? [game.mergedDump].compactMap({ $0 }) : real {
                transfers.enqueueDownload(object, to: folder)
            }
            destinations.append((game, [game.name, displayName(game)], folder))
        }

        guard includeSaves, let saves = dbiLayout?.saves else { return }
        Task {
            let saveFolders = await self.saveFolders(in: saves)
            for destination in destinations {
                let keys = Set(destination.names.map(SwitchFileInfo.normalize))
                let appID = destination.game.applicationID?.description
                let matches = saveFolders.filter { folder in
                    keys.contains(SwitchFileInfo.normalize(SwitchFileInfo.cleanTitle(folder.name)))
                        || (appID.map { folder.name.uppercased().contains($0) } ?? false)
                }
                for save in matches {
                    transfers.enqueueDownload(save, to: destination.folder)
                }
            }
        }
    }

    /// Copies DBI's whole Saves storage into a dated folder.
    func backUpAllSaves(layout: DBILayout) {
        guard let saves = layout.saves,
              let (directory, _) = chooseBackupFolder(title: "Back Up All Saves", offerSaves: false)
        else { return }
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let folder = Self.uniqueURL(in: directory, name: "Switch Saves \(stamp)")
        Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for object in try await session.contents(storageID: saves.id) {
                    transfers.enqueueDownload(object, to: folder)
                }
            } catch {
                report("Couldn't back up saves", error)
            }
        }
    }

    /// Per-game save folders, from DBI's "Saves/Installed games" and "Saves/Uninstalled games".
    private func saveFolders(in saves: MTPStorage) async -> [MTPObject] {
        guard let groups = try? await session.contents(storageID: saves.id) else { return [] }
        var folders: [MTPObject] = []
        for group in groups where group.isFolder {
            folders += (try? await session.contents(storageID: saves.id, parent: group.handle))?.filter(\.isFolder) ?? []
        }
        return folders
    }

    private func chooseBackupFolder(title: String, offerSaves: Bool) -> (URL, Bool)? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Back Up Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        var checkbox: NSButton?
        if offerSaves {
            let box = NSButton(checkboxWithTitle: "Include save data", target: nil, action: nil)
            box.state = (UserDefaults.standard.object(forKey: "backupIncludesSaves") as? Bool ?? true) ? .on : .off
            panel.accessoryView = box
            panel.isAccessoryViewDisclosed = true
            checkbox = box
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let includeSaves = checkbox?.state == .on
        if checkbox != nil { UserDefaults.standard.set(includeSaves, forKey: "backupIncludesSaves") }
        return (url, includeSaves)
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    private static func uniqueURL(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) \(counter)")
            counter += 1
        }
        return candidate
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
        if !transfers.hasActiveTransfers, !pendingEventChanges.isEmpty {
            scheduleEventRefresh()
        }
        let isInstall = [dbiLayout?.sdInstall?.id, dbiLayout?.nandInstall?.id].contains(transfer.storageID)
        if isInstall, case .failed = transfer.state, SwitchFileInfo(fileName: transfer.name).isCompressed {
            // DBI rejects NCZ content at the end of the transfer with a generic error when it runs as an applet.
            transfer.state = .failed("DBI couldn't install this compressed file. \(SwitchFileInfo.titleModeHint)")
        }
        if case .failed(let message) = transfer.state {
            onError?("Transfer of “\(transfer.name)” failed", MTPError.localFile(message))
        }
        guard transfer.direction == .upload else { return }
        if let candidate = installCandidates.removeValue(forKey: transfer.id), transfer.state == .completed {
            library.recordInstall(candidate)
        }
        Task {
            if transfer.parent == currentParent, transfer.storageID == selectedStorageID {
                await reload()
            }
            await refreshStorageInfo()
            if isInstall, transfer.state == .completed, !transfers.hasActiveTransfers {
                await reloadLibrary(refreshSession: true)
            }
        }
    }

    // MARK: - Drag to Finder

    /// Scratch space for drags; Finder copies the file out of here when the drop completes.
    static let dragDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SlopMTP Drags", isDirectory: true)

    private func freshDragDirectory() throws -> URL {
        let directory = Self.dragDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A promise for a device file or folder: it's downloaded (through the transfer queue, with
    /// progress) only when dropped, then handed to the drop destination.
    func dragProvider(for object: MTPObject) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = object.name
        let type = object.isFolder ? UTType.folder : UTType(filenameExtension: (object.name as NSString).pathExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [weak self] completion in
            let progress = Progress(totalUnitCount: Int64(clamping: max(object.size, 1)))
            let reply = UncheckedSendable(completion)
            let sendableProgress = UncheckedSendable(progress)
            Task { @MainActor in
                guard let self else { return reply.value(nil, false, MTPError.disconnected) }
                do {
                    let url = try await self.transfers.downloadAndWait(object, to: self.freshDragDirectory(), progress: sendableProgress.value)
                    reply.value(url, false, nil)
                } catch {
                    reply.value(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    /// A promise for one or more installed games: a folder per game (or a folder of game folders).
    func dragProvider(for games: [InstalledGame], displayName: @escaping (InstalledGame) -> String) -> NSItemProvider {
        let provider = NSItemProvider()
        let name = games.count == 1 ? Self.sanitize(displayName(games[0])) : "\(games.count) Switch Games"
        provider.suggestedName = name
        let jobs = games.map { game in
            let real = game.contents.map(\.object).filter { $0.storageID != 0 }
            return (folder: Self.sanitize(displayName(game)), objects: real.isEmpty ? [game.mergedDump].compactMap { $0 } : real)
        }
        let total = jobs.flatMap(\.objects).reduce(UInt64(0)) { $0 + $1.size }
        provider.registerFileRepresentation(forTypeIdentifier: UTType.folder.identifier, fileOptions: [], visibility: .all) { [weak self] completion in
            let progress = Progress(totalUnitCount: Int64(clamping: max(total, 1)))
            let reply = UncheckedSendable(completion)
            let sendableProgress = UncheckedSendable(progress)
            Task { @MainActor in
                guard let self else { return reply.value(nil, false, MTPError.disconnected) }
                do {
                    let root = try self.freshDragDirectory().appendingPathComponent(name, isDirectory: true)
                    for job in jobs {
                        let folder = jobs.count == 1 ? root : root.appendingPathComponent(job.folder, isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        for object in job.objects {
                            let step = Progress(totalUnitCount: Int64(clamping: max(object.size, 1)))
                            sendableProgress.value.addChild(step, withPendingUnitCount: Int64(clamping: object.size))
                            _ = try await self.transfers.downloadAndWait(object, to: folder, progress: step)
                        }
                    }
                    reply.value(root, false, nil)
                } catch {
                    reply.value(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    private func report(_ title: String, _ error: Error) {
        if case MTPError.disconnected = error { isDisconnected = true }
        onError?(title, error)
    }
}

/// Carries a value into a `Task` across a `@Sendable` boundary when access is serialized by design.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
