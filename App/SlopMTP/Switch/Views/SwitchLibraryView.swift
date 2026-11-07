import MTPKit
import SwiftUI

struct SwitchLibraryView: View {
    @Bindable var connection: DeviceConnection
    let layout: DBILayout

    @State private var search = ""
    @State private var sort: Sort = .name
    @State private var isDropTargeted = false
    @State private var selectedGame: InstalledGame?

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
        .softTopEdge()
        .background { AmbientBackground(colors: [.red, .indigo, .teal]) }
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
        .sheet(item: $selectedGame) { game in
            GameDetailView(game: game, connection: connection)
        }
        .sheet(isPresented: installSheetBinding) {
            InstallReviewSheet(connection: connection, layout: layout)
        }
        .navigationTitle("Library")
        .navigationSubtitle(connection.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if library.isLoading || database.state == .downloading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    connection.chooseFilesToInstall()
                } label: {
                    Label("Install Games", systemImage: "plus")
                }
                .help("Install games, updates or DLC")
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
                Text("\(library.games.count) Games Installed")
                    .font(.largeTitle.bold())
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20, alignment: .top)], alignment: .leading, spacing: 24) {
                    ForEach(visibleGames) { game in
                        Button {
                            selectedGame = game
                        } label: {
                            GameCard(game: game, displayName: displayName(game))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Details…") { selectedGame = game }
                            if game.mergedDump != nil || !game.contents.isEmpty {
                                Button("Back Up to Mac…") { connection.backUp(game) }
                            }
                            if game.folder != nil {
                                Button("Show in Files") { connection.showInFiles(game, layout: layout) }
                            }
                        }
                    }
                }
            }
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
        .glassPanel(cornerRadius: 24, tint: isTargeted ? .accentColor.opacity(0.35) : nil, interactive: true)
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.white.opacity(0.18))
                .padding(6)
        }
        .scaleEffect(isTargeted ? 1.01 : 1)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

struct GameCard: View {
    let game: InstalledGame
    let displayName: String
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverArtView(titleID: game.applicationID, name: displayName, cornerRadius: 14)
                .shadow(color: .black.opacity(isHovered ? 0.35 : 0.15), radius: isHovered ? 10 : 4, y: isHovered ? 6 : 2)
            Text(displayName)
                .font(.headline)
                .lineLimit(2, reservesSpace: true)
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
        .accessibilityHint("Shows details")
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
