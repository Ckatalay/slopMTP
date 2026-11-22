import Foundation

/// Keeps the Mac from idle-sleeping while transfers or installs run, so a long install isn't cut
/// off halfway. The display may still turn off. Controlled by a setting that defaults to on.
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()
    static let settingKey = "keepMacAwakeDuringTransfers"

    private var transfersRunning = false
    private var activity: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?

    private init() {
        UserDefaults.standard.register(defaults: [Self.settingKey: true])
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { KeepAwake.shared.update() }
        }
    }

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.settingKey) }

    func setTransfersRunning(_ running: Bool) {
        guard running != transfersRunning else { return }
        transfersRunning = running
        update()
    }

    private func update() {
        let shouldHold = transfersRunning && isEnabled
        if shouldHold, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: String(localized: "Transferring files to or from the Switch", comment: "Reason shown by macOS power tools (pmset, Activity Monitor) for why slopMTP keeps the Mac awake")
            )
        } else if !shouldHold, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
