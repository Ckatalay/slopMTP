import SwiftUI

struct SettingsView: View {
    @AppStorage(TitleDatabase.onlineLookupsKey) private var fetchArtwork = true
    @AppStorage(KeepAwake.settingKey) private var keepAwake = true

    var body: some View {
        Form {
            Toggle("Download game names and cover art", isOn: $fetchArtwork)
            Text("Uses the community title database on GitHub (about 90 MB, refreshed monthly) and Nintendo's eShop image servers. Only public title IDs are looked up; nothing about your console is sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Keep Mac awake during transfers", isOn: $keepAwake)
            Text("Stops your Mac from going to sleep while games install or files copy, so long transfers aren't cut off. The display can still turn off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}
