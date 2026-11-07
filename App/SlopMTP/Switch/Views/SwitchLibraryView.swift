import MTPKit
import SwiftUI

struct SwitchLibraryView: View {
    @Bindable var connection: DeviceConnection
    let layout: DBILayout

    @State private var search = ""
    @AppStorage("librarySort") private var sort: Sort = .nameAscending
    @AppStorage("libraryViewMode") private var viewMode: ViewMode = .grid
    @State private var isDropTargeted = false
    @State private var detailGame: InstalledGame?
    @State private var selection: Set<String> = []
    @State private var selectionAnchor: String?
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var marquee: CGRect?
    @State private var marqueeBase: Set<String> = []
    @State private var marqueeStart: CGPoint = .zero
    @State private var marqueeCurrent: CGPoint = .zero
    @State private var autoscroller = EdgeAutoscroller()
    @FocusState private var isGridFocused: Bool

    nonisolated private static let gridSpace = "libraryGrid"

    enum Sort: String, CaseIterable, Identifiable {
        case nameAscending, nameDescending, sizeDescending, sizeAscending
        var id: String { rawValue }

        var label: String {
            switch self {
            case .nameAscending: return "Name (A–Z)"
            case .nameDescending: return "Name (Z–A)"
            case .sizeDescending: return "Size (Largest First)"
            case .sizeAscending: return "Size (Smallest First)"
            }
        }
    }

    enum ViewMode: String, CaseIterable, Identifiable {
        case grid, list
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
        let byName: (InstalledGame, InstalledGame) -> Bool = {
            displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending
        }
        switch sort {
        case .nameAscending: return games.sorted(by: byName)
        case .nameDescending: return games.sorted { byName($1, $0) }
        case .sizeDescending: return games.sorted { $0.totalSize != $1.totalSize ? $0.totalSize > $1.totalSize : byName($0, $1) }
        case .sizeAscending: return games.sorted { $0.totalSize != $1.totalSize ? $0.totalSize < $1.totalSize : byName($0, $1) }
        }
    }

    var body: some View {
        content
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

    /// The grid scrolls as one page; the list keeps the header fixed and lets the table scroll.
    @ViewBuilder
    private var content: some View {
        switch viewMode {
        case .grid:
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    InstallActivityView(connection: connection, layout: layout)
                    installedSection
                }
                .padding(24)
            }
            .softVerticalEdges()
        case .list:
            VStack(alignment: .leading, spacing: 20) {
                header
                InstallActivityView(connection: connection, layout: layout)
                installedSection
            }
            .padding([.horizontal, .top], 24)
        }
    }

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
            HStack(spacing: 12) {
                Text("Installed")
                    .font(.title2.bold())
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Picker("View", selection: $viewMode) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                    Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show as grid or list")
            }

            if library.games.isEmpty {
                ContentUnavailableView {
                    Label(library.isLoading ? "Loading Library…" : "No Games Installed", systemImage: "gamecontroller")
                } description: {
                    if let error = library.lastError { Text(error) }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if viewMode == .grid {
                grid
            } else {
                list
            }
        }
    }

    // MARK: - List

    private var list: some View {
        Table(visibleGames, selection: $selection, sortOrder: tableSortOrder) {
            TableColumn("Name", value: \.name) { game in
                HStack(spacing: 10) {
                    CoverArtView(titleID: game.applicationID, name: displayName(game), cornerRadius: 6)
                        .frame(width: 32, height: 32)
                    Text(displayName(game))
                        .lineLimit(1)
                    if !game.hasBase, game.contentsLoaded || game.summary != nil {
                        Badge(text: "No base", color: .orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Drag a game out to Finder; a selected row takes the whole selection.
                .gesture(DragGesture(minimumDistance: 6).onChanged { _ in
                    guard !connection.finderDrag.isDragging else { return }
                    connection.beginFinderDrag(for: selection.contains(game.id) ? selectedGames : [game], displayName: displayName)
                })
            }
            TableColumn("Update") { game in
                Text(game.updateVersion.map(TitleVersion.short) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn("DLC") { game in
                Text(game.dlcCount > 0 ? "\(game.dlcCount)" : "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 50, max: 70)
            TableColumn("Size", value: \.totalSize) { game in
                Text(game.totalSize > 0 ? Format.bytes(game.totalSize) : "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90, max: 120)
            TableColumn("Title ID") { game in
                Text(game.applicationID?.description ?? "—")
                    .font(.callout.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .width(min: 140, ideal: 160, max: 180)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let targets = visibleGames.filter { ids.contains($0.id) }
            if targets.count == 1, let game = targets.first {
                Button("Details…") { detailGame = game }
            }
            if !targets.isEmpty {
                Button(targets.count == 1 ? "Back Up to Mac…" : "Back Up \(targets.count) Games to Mac…") {
                    connection.backUp(targets, displayName: displayName)
                }
            }
            if targets.count == 1, let game = targets.first, game.folder != nil {
                Button("Show in Files") { connection.showInFiles(game, layout: layout) }
            }
        } primaryAction: { ids in
            if ids.count == 1, let game = visibleGames.first(where: { ids.contains($0.id) }) {
                detailGame = game
            }
        }
        .softVerticalEdges()
    }

    /// Bridges the table's sortable column headers to the shared sort setting. The key paths only
    /// identify the column; rows are always ordered by `visibleGames`, which sorts by display name.
    private var tableSortOrder: Binding<[KeyPathComparator<InstalledGame>]> {
        Binding(
            get: {
                switch sort {
                case .nameAscending: return [KeyPathComparator(\.name, comparator: .localizedStandard)]
                case .nameDescending: return [KeyPathComparator(\.name, comparator: .localizedStandard, order: .reverse)]
                case .sizeDescending: return [KeyPathComparator(\.totalSize, order: .reverse)]
                case .sizeAscending: return [KeyPathComparator(\.totalSize)]
                }
            },
            set: { comparators in
                guard let first = comparators.first else { return }
                if first.keyPath == \InstalledGame.totalSize {
                    sort = first.order == .forward ? .sizeAscending : .sizeDescending
                } else {
                    sort = first.order == .forward ? .nameAscending : .nameDescending
                }
            }
        )
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
                    .simultaneousGesture(TapGesture().onEnded { click(game) })
                    // Dragging a cover hands it to Finder as a file promise; dragging a selected
                    // game takes the whole selection, like Finder.
                    .gesture(DragGesture(minimumDistance: 6).onChanged { _ in
                        guard !connection.finderDrag.isDragging else { return }
                        connection.beginFinderDrag(for: selection.contains(game.id) ? selectedGames : [game], displayName: displayName)
                    })
                    .contextMenu { contextMenu(for: game) }
            }
        }
        // The rubber band and click-to-deselect live on the empty background behind the cards,
        // so a drag that starts on a card is always a drag to Finder.
        .background {
            // Extends into the margins around the grid, so a rubber band can start beside,
            // above or below the cards, not only in the gaps between them.
            // The hit shape goes on the expanded view, before the negative padding shrinks the
            // reported frame back to the grid's size.
            Color.clear
                .contentShape(Rectangle())
                .padding(.horizontal, -24)
                .padding(.top, -12)
                .padding(.bottom, -24)
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
                    // Scroll when the pointer nears the top or bottom edge; the content moves under a
                    // still pointer, so shift the rectangle's moving corner by the scrolled amount.
                    autoscroller.begin { delta in
                        marqueeCurrent.y += delta
                        updateMarquee()
                    }
                }
                marqueeStart = value.startLocation
                marqueeCurrent = value.location
                updateMarquee()
            }
            .onEnded { _ in
                autoscroller.end()
                marquee = nil
                selectionAnchor = selection.count == 1 ? selection.first : selectionAnchor
            }
    }

    private func updateMarquee() {
        let rect = CGRect(
            x: min(marqueeStart.x, marqueeCurrent.x),
            y: min(marqueeStart.y, marqueeCurrent.y),
            width: abs(marqueeCurrent.x - marqueeStart.x),
            height: abs(marqueeCurrent.y - marqueeStart.y)
        )
        marquee = rect
        let visibleIDs = Set(visibleGames.map(\.id))
        let hit = cardFrames.filter { visibleIDs.contains($0.key) && $0.value.intersects(rect) }.keys
        selection = marqueeBase.union(hit)
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

struct GameCard: View {
    let game: InstalledGame
    let displayName: String
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverArtView(titleID: game.applicationID, name: displayName, cornerRadius: 14)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
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

/// Scrolls the scroll view under the pointer while it's held near (or past) its top or bottom edge,
/// faster the closer it gets. Runs on a timer, so it keeps going while the pointer is still.
@MainActor
final class EdgeAutoscroller {
    private weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var onScroll: ((CGFloat) -> Void)?

    private let edgeZone: CGFloat = 48
    private let maxStep: CGFloat = 24

    func begin(onScroll: @escaping (CGFloat) -> Void) {
        end()
        guard let event = NSApp.currentEvent, let window = event.window, let content = window.contentView else { return }
        var view = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let current = view, !(current is NSScrollView) { view = current.superview }
        guard let scrollView = view as? NSScrollView else { return }
        self.scrollView = scrollView
        self.onScroll = onScroll
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func end() {
        timer?.invalidate()
        timer = nil
        scrollView = nil
        onScroll = nil
    }

    private func tick() {
        guard let scrollView, let window = scrollView.window, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let pointer = clip.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let visible = clip.bounds
        // Distances to the visible top and bottom in the clip view's own orientation.
        let fromTop = clip.isFlipped ? pointer.y - visible.minY : visible.maxY - pointer.y
        let fromBottom = clip.isFlipped ? visible.maxY - pointer.y : pointer.y - visible.minY

        var step: CGFloat = 0
        if fromTop < edgeZone {
            step = -maxStep * min(1, (edgeZone - fromTop) / edgeZone)
        } else if fromBottom < edgeZone {
            step = maxStep * min(1, (edgeZone - fromBottom) / edgeZone)
        }
        guard step != 0 else { return }

        // `step` is in "towards the end of the document" terms; convert to the clip's y axis.
        let maxOffset = max(0, document.frame.height - visible.height)
        let oldY = visible.origin.y
        let wanted = clip.isFlipped ? oldY + step : oldY - step
        let newY = min(max(wanted, clip.isFlipped ? 0 : document.frame.minY), clip.isFlipped ? maxOffset : document.frame.maxY - visible.height)
        guard newY != oldY else { return }
        clip.scroll(to: NSPoint(x: visible.origin.x, y: newY))
        scrollView.reflectScrolledClipView(clip)
        onScroll?(clip.isFlipped ? newY - oldY : oldY - newY)
    }
}
