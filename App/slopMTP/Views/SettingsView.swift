import SwiftUI

struct SettingsView: View {
    @AppStorage(TitleDatabase.onlineLookupsKey) private var fetchArtwork = true

    var body: some View {
        Form {
            Toggle("Download game names and cover art", isOn: $fetchArtwork)
            Text("Uses the community title database on GitHub (about 90 MB, refreshed monthly) and Nintendo's eShop image servers. Only public title IDs are looked up; nothing about your console is sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}
