import MTPKit
import SwiftUI

/// Review sheet shown after dropping files: what each file is, whether it's needed, and where it goes.
struct InstallReviewSheet: View {
    @Bindable var connection: DeviceConnection
    let layout: DBILayout
    @Environment(\.dismiss) private var dismiss

    private var selected: [InstallCandidate] { connection.pendingInstall.filter(\.isSelected) }
    private var totalSize: UInt64 { selected.reduce(0) { $0 + $1.size } }
    private var freeSpace: UInt64? { layout.storage(for: connection.installTarget)?.info.freeSpaceInBytes }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install \(connection.pendingInstall.count == 1 ? "1 File" : "\(connection.pendingInstall.count) Files")")
                    .font(.title2.bold())
                Text("Base games install first, then updates, then DLC. Items already on the console are unchecked.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            if selected.contains(where: { $0.info.isCompressed }) {
                Label {
                    Text(SwitchFileInfo.titleModeHint)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                }
                .font(.callout)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            List {
                ForEach($connection.pendingInstall) { $candidate in
                    CandidateRow(candidate: $candidate)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 240)

            Divider()

            HStack(spacing: 16) {
                Picker("Install to", selection: $connection.installTarget) {
                    ForEach(DBILayout.InstallTarget.allCases) { target in
                        Text(target.label).tag(target)
                            .disabled(layout.storage(for: target) == nil)
                    }
                }
                .fixedSize()

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Format.bytes(totalSize)) selected")
                        .monospacedDigit()
                    if let freeSpace {
                        Text("\(Format.bytes(freeSpace)) free")
                            .font(.caption)
                            .foregroundStyle(totalSize > freeSpace ? .red : .secondary)
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    connection.pendingInstall = []
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(selected.count == 1 ? "Install 1 Item" : "Install \(selected.count) Items") {
                    connection.startPendingInstall()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || layout.storage(for: connection.installTarget) == nil)
            }
            .padding(20)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 440)
    }
}

private struct CandidateRow: View {
    @Binding var candidate: InstallCandidate

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $candidate.isSelected)
                .labelsHidden()
                .accessibilityLabel("Install \(candidate.info.title)")
            CoverArtView(titleID: candidate.titleID, name: candidate.info.title, cornerRadius: 6)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(TitleDatabase.shared.entry(for: candidate.titleID ?? TitleID(0))?.name ?? candidate.info.title)
                        .lineLimit(1)
                    Badge(text: candidate.kind.label, color: color(for: candidate.kind))
                    if candidate.kind == .update {
                        Badge(text: TitleVersion.short(candidate.version), color: .blue)
                    }
                }
                HStack(spacing: 6) {
                    if candidate.status.isWarning {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(candidate.status.message)
                        .foregroundStyle(candidate.status.isWarning ? .orange : .secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(candidate.url.lastPathComponent)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
            }
            Spacer()
            Text(Format.bytes(candidate.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .opacity(candidate.isSelected ? 1 : 0.55)
    }

    private func color(for kind: TitleID.Kind) -> Color {
        switch kind {
        case .application: return .green
        case .update: return .blue
        case .addOn: return .purple
        }
    }
}

/// Installs and copies to the Mac (backups, drags to Finder), shown above the library grid.
struct InstallActivityView: View {
    let connection: DeviceConnection
    let layout: DBILayout

    private var installs: [Transfer] { connection.transfers.transfers }

    private var title: String {
        let directions = Set(installs.map(\.direction))
        if directions == [.upload] { return "Installing" }
        if directions == [.download] { return "Copying to Mac" }
        return "Transfers"
    }

    var body: some View {
        if !installs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title)
                        .font(.title2.bold())
                    Spacer()
                    if connection.transfers.hasFinishedTransfers {
                        Button("Clear Finished") { connection.transfers.clearFinished() }
                            .buttonStyle(.borderless)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(installs) { transfer in
                        InstallRow(transfer: transfer) { connection.transfers.cancel(transfer) }
                        if transfer.id != installs.last?.id { Divider() }
                    }
                }
                .glassPanel(cornerRadius: 20)
            }
        }
    }
}

private struct InstallRow: View {
    let transfer: Transfer
    let cancel: () -> Void

    var body: some View {
        let info = SwitchFileInfo(fileName: transfer.name)
        HStack(spacing: 12) {
            CoverArtView(titleID: info.titleID, name: info.title, cornerRadius: 8)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(info.titleID.flatMap { TitleDatabase.shared.entry(for: $0)?.name } ?? info.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let kind = info.kind {
                        Text(kind == .update ? "Update \(TitleVersion.short(info.version ?? 0))" : kind.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                switch transfer.state {
                case .running, .preparing:
                    ProgressView(value: transfer.fractionCompleted)
                    Text(progressText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                case .queued:
                    Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                case .completed:
                    Label(transfer.direction == .download ? "Copied to Mac" : "Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if transfer.retry != nil, transfer.state != .completed, transfer.state.isFinished {
                Button {
                    transfer.retry?()
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(transfer.direction == .download ? "Retry (resumes where it stopped)" : "Retry")
                .accessibilityLabel("Retry \(info.title)")
            }
            if !transfer.state.isFinished {
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancel")
                .accessibilityLabel("Cancel installing \(info.title)")
            }
        }
        .padding(12)
    }

    private var progressText: String {
        var parts = ["\(transfer.direction == .download ? "Copying to Mac" : "Installing") · \(Format.bytes(transfer.completedBytes)) of \(Format.bytes(transfer.totalBytes))"]
        if let speed = transfer.bytesPerSecond, speed > 0 {
            parts.append("\(Format.bytes(UInt64(speed)))/s")
            let remaining = Double(transfer.totalBytes - min(transfer.completedBytes, transfer.totalBytes)) / speed
            parts.append("\(Format.duration(remaining)) left")
        }
        return parts.joined(separator: " · ")
    }
}

/// Details for one installed game: artwork, metadata and its base / update / DLC contents.
struct GameDetailView: View {
    let game: InstalledGame
    let connection: DeviceConnection
    @Environment(\.dismiss) private var dismiss

    private var entry: TitleDatabase.Entry? { game.applicationID.flatMap { TitleDatabase.shared.entry(for: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                CoverArtView(titleID: game.applicationID, name: game.name, cornerRadius: 16)
                    .frame(width: 160, height: 160)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry?.name ?? game.name)
                        .font(.title.bold())
                        .textSelection(.enabled)
                    if let publisher = entry?.publisher {
                        Text(publisher).foregroundStyle(.secondary)
                    }
                    if let date = entry?.releaseDate.flatMap(Self.releaseDate) {
                        Text("Released \(date.formatted(date: .long, time: .omitted))")
                            .foregroundStyle(.secondary)
                    }
                    if let id = game.applicationID {
                        Text(id.description)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 4) {
                        if let version = game.updateVersion { Badge(text: "Update \(TitleVersion.short(version))", color: .blue) }
                        if game.dlcCount > 0 { Badge(text: "\(game.dlcCount) DLC", color: .purple) }
                    }
                    .padding(.top, 4)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Contents").font(.headline)
                if game.contents.isEmpty {
                    Text(game.contentsLoaded ? "DBI didn't list individual contents for this game." : "Loading…")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(game.contents) { content in
                            HStack {
                                Badge(text: content.kind.label, color: content.kind == .application ? .green : content.kind == .update ? .blue : .purple)
                                Text(content.info.title)
                                    .lineLimit(1)
                                if let version = content.info.version, content.kind == .update {
                                    Text(TitleVersion.display(version)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(content.titleID?.description ?? "")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                Text(Format.bytes(content.object.size))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .trailing)
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }

            HStack {
                if game.mergedDump != nil || !game.contents.isEmpty {
                    Button("Back Up to Mac…") { connection.backUp(game) }
                        .help("Saves a copy of this game's installed content to your Mac")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private static func releaseDate(_ value: Int) -> Date? {
        DateComponents(calendar: Calendar(identifier: .gregorian), year: value / 10000, month: value / 100 % 100, day: value % 100).date
    }
}
