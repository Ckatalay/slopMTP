import MTPKit
import SwiftUI

/// DBI's Album storage as a gallery: screenshots and videos grouped by game.
struct AlbumView: View {
    let connection: DeviceConnection
    let layout: DBILayout
    let storage: MTPStorage

    @State private var selection: Set<UInt32> = []
    @State private var anchor: UInt32?

    private var album: AlbumLibrary { connection.album }
    private var items: [MTPObject] { album.allItems }
    private var selectedItems: [MTPObject] { items.filter { selection.contains($0.handle) } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                header
                ForEach(album.sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(section.name)
                                .font(.title2.bold())
                            Text("\(section.items.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)], spacing: 14) {
                            ForEach(section.items) { item in
                                AlbumTile(item: item, session: connection.session, isSelected: selection.contains(item.handle))
                                    .simultaneousGesture(TapGesture().onEnded { click(item) })
                                    .gesture(DragGesture(minimumDistance: 6).onChanged { _ in
                                        guard !connection.finderDrag.isDragging else { return }
                                        connection.beginFinderDrag(for: selection.contains(item.handle) ? selectedItems : [item])
                                    })
                                    .contextMenu { contextMenu(for: item) }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selection = [] }
            }
        }
        .softVerticalEdges()
        .overlay {
            if album.sections.isEmpty {
                if album.isLoading {
                    ProgressView(connection.transfers.hasActiveTransfers ? "Waiting for the current transfer to finish…" : "Loading album…")
                } else if album.hasLoaded || album.lastError != nil {
                    ContentUnavailableView {
                        Label("No Captures", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        if let error = album.lastError { Text(error) }
                    }
                }
            }
        }
        .edgeBar(.bottom) {
            if !selection.isEmpty {
                HStack(spacing: 14) {
                    Text(selection.count == 1 ? "1 item selected" : "\(selection.count) items selected")
                        .font(.headline)
                    Spacer()
                    Button("Deselect") { selection = [] }
                        .glassButtonStyle()
                    Button("Save to Mac…") { connection.chooseDownloadDestination(for: selectedItems) }
                        .glassButtonStyle(prominent: true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassPanel(cornerRadius: 22)
                .frame(maxWidth: 520)
                .padding(12)
            }
        }
        .onExitCommand { selection = [] }
        .onCommand(#selector(NSResponder.selectAll(_:))) { selection = Set(items.map(\.handle)) }
        .task {
            if !album.hasLoaded { await connection.reloadAlbum() }
        }
        .navigationTitle("Album")
        .navigationSubtitle(connection.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    connection.backUpAlbum(layout: layout)
                } label: {
                    Label("Save Album", systemImage: "square.and.arrow.down.on.square")
                }
                .help("Save the whole album to your Mac")
                Button {
                    Task { await connection.reloadAlbum() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh album")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(items.count == 1 ? "1 Capture" : "\(items.count) Captures")
                .font(.largeTitle.bold())
            if album.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading")
            }
        }
    }

    private func click(_ item: MTPObject) {
        let modifiers = NSEvent.modifierFlags
        if NSApp.currentEvent?.clickCount == 2, !modifiers.contains(.command), !modifiers.contains(.shift) {
            selection = [item.handle]
            connection.openOnMac(item)
        } else if modifiers.contains(.command) {
            if selection.contains(item.handle) { selection.remove(item.handle) } else { selection.insert(item.handle) }
            anchor = item.handle
        } else if modifiers.contains(.shift), let anchor,
                  let from = items.firstIndex(where: { $0.handle == anchor }),
                  let to = items.firstIndex(where: { $0.handle == item.handle }) {
            selection.formUnion(items[min(from, to)...max(from, to)].map(\.handle))
        } else {
            selection = [item.handle]
            anchor = item.handle
        }
    }

    @ViewBuilder
    private func contextMenu(for item: MTPObject) -> some View {
        let targets = selection.contains(item.handle) ? selectedItems : [item]
        if targets.count == 1 {
            Button("Open") { connection.openOnMac(item) }
        }
        Button(targets.count == 1 ? "Save to Mac…" : "Save \(targets.count) Items to Mac…") {
            connection.chooseDownloadDestination(for: targets)
        }
    }
}

private struct AlbumTile: View {
    let item: MTPObject
    let session: MTPSession
    let isSelected: Bool

    @State private var image: NSImage?

    private var isVideo: Bool { AlbumMedia.isVideo(item.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    Image(systemName: isVideo ? "film" : "photo")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                }
                if isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(8)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(3)
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .opacity(isSelected ? 1 : 0)
            }
            Text(AlbumMedia.captureDate(item)?.formatted(date: .abbreviated, time: .shortened) ?? item.name)
                .font(.caption)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .task(id: item.handle) {
            guard image == nil, !isVideo else { return }
            if let data = await ThumbnailLoader.shared.thumbnail(for: item, session: session), let loaded = NSImage(data: data) {
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isVideo ? "Video" : "Screenshot")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
