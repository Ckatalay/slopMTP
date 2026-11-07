import MTPKit
import OSLog
import SwiftUI

private let dragLog = Logger(subsystem: "io.github.ckatalay.SlopMTP", category: "drag")

struct SwitchLibraryView: View {
    @Bindable var connection: DeviceConnection
    let layout: DBILayout

    @State private var search = ""
    @State private var sort: Sort = .name
    @State private var isDropTargeted = false
    @State private var detailGame: InstalledGame?
    @State private var selection: Set<String> = []
    @State private var selectionAnchor: String?
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var marquee: CGRect?
    @State private var marqueeBase: Set<String> = []
    @FocusState private var isGridFocused: Bool

    nonisolated private static let gridSpace = "libraryGrid"

    enum Sort: String, CaseIterable, Identifiable {
        case name = "Name"
        case size = "Size"
        var id: String { rawValue }
    }

    private var library: SwitchLibrary { connection.library }
    private var database: TitleDatabase { TitleDatabase.shared }

    private var visibleGames: [InstalledGame] {
        var games = library.games
        if !search.isEmpty {
            games = games.filter { game in
                game.name.localizedCaseInsensitiveContains(search)
                    || displayName(game).localizedCaseInsensitiveContains(search)
                    || game.applicationID?.description.localizedCaseInsensitiveContains(search) == true
            }
        }
        switch sort {
        case .name: return games.sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
        case .size: return games.sorted { $0.totalSize > $1.totalSize }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                DropZone(isTargeted: isDropTargeted, targetLabel: connection.installTarget.label) {
                    connection.chooseFilesToInstall()
                }
                InstallActivityView(connection: connection, layout: layout)
                installedSection
            }
            .padding(24)
        }
        .softVerticalEdges()
        .focusable()
        .focusEffectDisabled()
        .focused($isGridFocused)
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            selection = Set(visibleGames.map(\.id))
        }
        .onExitCommand { selection = [] }
        .onKeyPress(.return) {
            guard selection.count == 1, let game = selectedGames.first else { return .ignored }
            detailGame = game
            return .handled
        }
        .edgeBar(.bottom) {
            if !selection.isEmpty {
                SelectionBar(
                    count: selectedGames.count,
                    size: selectedGames.reduce(0) { $0 + $1.totalSize },
                    backUp: { connection.backUp(selectedGames, displayName: displayName) },
                    clear: { selection = [] }
                )
                .padding(12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: selection.isEmpty)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            connection.prepareInstall(files)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $detailGame) { game in
            GameDetailView(game: game, connection: connection)
        }
        .sheet(isPresented: installSheetBinding) {
            InstallReviewSheet(connection: connection, layout: layout)
        }
        .navigationTitle("Library")
        .navigationSubtitle(connection.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    connection.chooseFilesToInstall()
                } label: {
                    Label("Install Games", systemImage: "plus")
                }
                .help("Install games, updates or DLC")
                Menu {
                    Button(selection.isEmpty ? "Back Up Selected Games…" : "Back Up \(selection.count) Selected Games…") {
                        connection.backUp(selectedGames, displayName: displayName)
                    }
                    .disabled(selection.isEmpty)
                    Button("Back Up All Games…") {
                        connection.backUp(library.games, displayName: displayName)
                    }
                    .disabled(library.games.isEmpty)
                    Divider()
                    Button("Back Up All Saves…") { connection.backUpAllSaves(layout: layout) }
                        .disabled(layout.saves == nil)
                } label: {
                    Label("Back Up", systemImage: "externaldrive.badge.timemachine")
                }
                .help("Back up games or saves to your Mac")
                Button {
                    Task { await connection.reloadLibrary(refreshSession: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh library")
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search games")
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("\(library.games.count) Games Installed")
                        .font(.largeTitle.bold())
                    if library.isLoading || database.state == .downloading {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Loading")
                    }
                }
                Group {
                    switch database.state {
                    case .downloading:
                        Text("Downloading game names and artwork (one-time, about 90 MB)…")
                    case .failed(let message):
                        Text("Artwork unavailable: \(message)")
                    default:
                        Text("Drop games, updates or DLC anywhere in this window to install them.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            GlassGroup {
                HStack(spacing: 12) {
                    if let sd = layout.sdInstall { CapacityPill(title: "SD Card", storage: sd) }
                    if let nand = layout.nandInstall { CapacityPill(title: "System Memory", storage: nand) }
                }
            }
        }
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Installed")
                    .font(.title2.bold())
                Spacer()
                Picker("Sort by", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            if library.games.isEmpty {
                ContentUnavailableView {
                    Label(library.isLoading ? "Loading Library…" : "No Games Installed", systemImage: "gamecontroller")
                } description: {
                    if let error = library.lastError { Text(error) }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                grid
            }
        }
    }

    // MARK: - Selection

    private var selectedGames: [InstalledGame] {
        visibleGames.filter { selection.contains($0.id) }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20, alignment: .top)], alignment: .leading, spacing: 24) {
            ForEach(visibleGames) { game in
                GameCard(game: game, displayName: displayName(game), isSelected: selection.contains(game.id))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.gridSpace)) } action: { frame in
                        cardFrames[game.id] = frame
                    }
                    .onTapGesture { click(game) }
                    .onDrag {
                        dragLog.debug("drag card \(displayName(game), privacy: .public)")
                        // Dragging a selected game takes the whole selection, like Finder.
                        let games = selection.contains(game.id) ? selectedGames : [game]
                        return connection.dragProvider(for: games, displayName: displayName)
                    }
                    .contextMenu { contextMenu(for: game) }
            }
        }
        // The rubber band and click-to-deselect live on the empty background behind the cards,
        // so a drag that starts on a card is always a drag to Finder.
        .background {
            // Extends into the margins around the grid, so a rubber band can start beside,
            // above or below the cards, not only in the gaps between them.
            Color.clear
                .padding(.horizontal, -24)
                .padding(.top, -12)
                .padding(.bottom, -24)
                .contentShape(Rectangle())
                .onTapGesture {
                    isGridFocused = true
                    selection = []
                }
                .gesture(marqueeGesture)
        }
        .coordinateSpace(.named(Self.gridSpace))
        .overlay(alignment: .topLeading) {
            if let marquee {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.8)))
                    .frame(width: marquee.width, height: marquee.height)
                    .offset(x: marquee.minX, y: marquee.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Finder-style rubber-band selection; ⌘ or ⇧ extends the existing selection.
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                if marquee == nil {
                    isGridFocused = true
                    let modifiers = NSEvent.modifierFlags
                    marqueeBase = modifiers.contains(.command) || modifiers.contains(.shift) ? selection : []
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                marquee = rect
                let visibleIDs = Set(visibleGames.map(\.id))
                let hit = cardFrames.filter { visibleIDs.contains($0.key) && $0.value.intersects(rect) }.keys
                selection = marqueeBase.union(hit)
            }
            .onEnded { _ in
                marquee = nil
                selectionAnchor = selection.count == 1 ? selection.first : selectionAnchor
            }
    }

    private func click(_ game: InstalledGame) {
        isGridFocused = true
        let modifiers = NSEvent.modifierFlags
        // Read the click count from the event so single clicks select without waiting for a possible double click.
        if NSApp.currentEvent?.clickCount == 2, !modifiers.contains(.command), !modifiers.contains(.shift) {
            selection = [game.id]
            selectionAnchor = game.id
            detailGame = game
        } else if modifiers.contains(.command) {
            if selection.contains(game.id) { selection.remove(game.id) } else { selection.insert(game.id) }
            selectionAnchor = game.id
        } else if modifiers.contains(.shift), let anchor = selectionAnchor,
                  let from = visibleGames.firstIndex(where: { $0.id == anchor }),
                  let to = visibleGames.firstIndex(where: { $0.id == game.id }) {
            selection.formUnion(visibleGames[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [game.id]
            selectionAnchor = game.id
        }
    }

    @ViewBuilder
    private func contextMenu(for game: InstalledGame) -> some View {
        // Right-clicking outside the selection acts on just that game, like Finder.
        let targets = selection.contains(game.id) ? selectedGames : [game]
        if targets.count == 1 {
            Button("Details…") { detailGame = game }
        }
        Button(targets.count == 1 ? "Back Up to Mac…" : "Back Up \(targets.count) Games to Mac…") {
            connection.backUp(targets, displayName: displayName)
        }
        if targets.count == 1, game.folder != nil {
            Button("Show in Files") { connection.showInFiles(game, layout: layout) }
        }
    }

    private func displayName(_ game: InstalledGame) -> String {
        game.applicationID.flatMap { database.entry(for: $0)?.name } ?? game.name
    }

    private var installSheetBinding: Binding<Bool> {
        Binding(get: { !connection.pendingInstall.isEmpty }, set: { if !$0 { connection.pendingInstall = [] } })
    }
}

// MARK: - Components

private struct CapacityPill: View {
    let title: String
    let storage: MTPStorage

    var body: some View {
        let info = storage.info
        let used = info.maxCapacity - min(info.freeSpaceInBytes, info.maxCapacity)
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ProgressView(value: Double(used), total: Double(max(info.maxCapacity, 1)))
                .tint(info.freeSpaceInBytes < info.maxCapacity / 10 ? .orange : .accentColor)
            Text("\(Format.bytes(info.freeSpaceInBytes)) free")
                .font(.caption)
                .monospacedDigit()
        }
        .frame(width: 150)
        .padding(14)
        .glassPanel(cornerRadius: 18)
        .accessibilityElement(children: .combine)
    }
}

private struct DropZone: View {
    static let cornerRadius: CGFloat = 24

    let isTargeted: Bool
    let targetLabel: String
    let choose: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "square.and.arrow.down.on.square")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: isTargeted)
            VStack(alignment: .leading, spacing: 4) {
                Text(isTargeted ? "Release to review and install" : "Drop games, updates and DLC here")
                    .font(.title3.weight(.semibold))
                Text("NSP · NSZ · XCI · XCZ, or whole folders. Installs to \(targetLabel); base games install before updates and DLC.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose Files…", action: choose)
                .controlSize(.large)
                .glassButtonStyle(prominent: true)
        }
        .padding(22)
        .glassPanel(cornerRadius: Self.cornerRadius, tint: isTargeted ? .accentColor.opacity(0.35) : nil, interactive: true)
        .scaleEffect(isTargeted ? 1.01 : 1)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

struct GameCard: View {
    let game: InstalledGame
    let displayName: String
    var isSelected = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverArtView(titleID: game.applicationID, name: displayName, cornerRadius: 14)
                .shadow(color: .black.opacity(isHovered ? 0.35 : 0.15), radius: isHovered ? 10 : 4, y: isHovered ? 6 : 2)
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .opacity(isSelected ? 1 : 0)
                }
            Text(displayName)
                .font(.headline)
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
            HStack(spacing: 4) {
                if !game.hasBase, game.contentsLoaded || game.summary != nil {
                    Badge(text: "No base", color: .orange)
                }
                if let version = game.updateVersion {
                    Badge(text: TitleVersion.short(version), color: .blue)
                }
                if game.dlcCount > 0 {
                    Badge(text: "\(game.dlcCount) DLC", color: .purple)
                }
            }
            if game.totalSize > 0 {
                Text(Format.bytes(game.totalSize))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .scaleEffect(isHovered ? 1.03 : 1)
        .animation(.spring(duration: 0.25), value: isHovered)
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Double-click for details")
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .glassCapsule(tint: color.opacity(0.25))
    }
}

/// Floating glass bar summarizing the selection.
private struct SelectionBar: View {
    let count: Int
    let size: UInt64
    let backUp: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(count == 1 ? "1 game selected" : "\(count) games selected")
                    .font(.headline)
                if size > 0 {
                    Text(Format.bytes(size))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Deselect", action: clear)
                .glassButtonStyle()
            Button("Back Up…", action: backUp)
                .glassButtonStyle(prominent: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassPanel(cornerRadius: 22)
        .frame(maxWidth: 560)
    }
}
