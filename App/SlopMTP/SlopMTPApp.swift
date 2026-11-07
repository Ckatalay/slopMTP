import SwiftUI

@main
struct SlopMTPApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 520)
                .onAppear { model.start() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Folder…") { model.connection?.requestNewFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.connection?.canModify != true)
                Button("Upload…") { model.connection?.chooseFilesToUpload() }
                    .keyboardShortcut("u", modifiers: [.command])
                    .disabled(model.connection?.canModify != true)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.connection?.reload() } }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.connection == nil)
            }
        }
    }
}
