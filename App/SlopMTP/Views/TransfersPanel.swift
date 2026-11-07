import SwiftUI

struct TransfersPanel: View {
    let queue: TransferQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers")
                    .font(.headline)
                Spacer()
                if queue.hasFinishedTransfers {
                    Button("Clear Finished") { queue.clearFinished() }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queue.transfers.reversed()) { transfer in
                        TransferRow(transfer: transfer) { queue.cancel(transfer) }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 170)
        }
        .glassPanel(cornerRadius: 20)
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityLabel(transfer.direction == .download ? "Download" : "Upload")
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if transfer.state == .running || transfer.state == .preparing {
                    ProgressView(value: transfer.fractionCompleted)
                        .controlSize(.small)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer()
            if !transfer.state.isFinished {
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancel")
                .accessibilityLabel("Cancel transfer of \(transfer.name)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var tint: Color {
        switch transfer.state {
        case .failed: return .red
        case .cancelled: return .secondary
        case .completed: return .green
        default: return .accentColor
        }
    }

    private var status: String {
        switch transfer.state {
        case .queued:
            return "Waiting…"
        case .preparing:
            return "Preparing…"
        case .running:
            var parts = ["\(Format.bytes(transfer.completedBytes)) of \(Format.bytes(transfer.totalBytes))"]
            if let speed = transfer.bytesPerSecond, speed > 0 {
                parts.append("\(Format.bytes(UInt64(speed)))/s")
                let remaining = Double(transfer.totalBytes - min(transfer.completedBytes, transfer.totalBytes)) / speed
                parts.append(Format.duration(remaining) + " left")
            }
            if let file = transfer.currentFile, file != transfer.name {
                parts.append(file)
            }
            return parts.joined(separator: " · ")
        case .completed:
            var text = "Done · \(Format.bytes(transfer.totalBytes))"
            if let speed = transfer.bytesPerSecond, speed > 0 {
                text += " · \(Format.bytes(UInt64(speed)))/s"
            }
            return text
        case .failed(let message):
            return "Failed: \(message)"
        case .cancelled:
            return "Cancelled"
        }
    }
}
