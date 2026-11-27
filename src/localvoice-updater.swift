import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

// In-app updates through Sparkle (https://sparkle-project.org).
//
// Only builds that embed Sparkle.framework and name a feed in their Info.plist
// (SUFeedURL, SUPublicEDKey) have an updater: the signed releases and dev releases
// from CI. Everything else (local builds, the previews, `scripts/check.sh` without
// Sparkle) compiles the stub at the bottom, and `AppUpdater.make()` returns nil.
//
// Sparkle asks on the second launch whether to check automatically; until the user
// says yes, LocalVoice contacts no update server on its own. A found update goes into
// the menu bar menu and Settings instead of a window over whatever the user is doing
// (Sparkle's "gentle reminders" for background apps).

#if canImport(Sparkle)
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    /// Called when `availableVersion` or the automatic setting changes.
    var onChange: (() -> Void)?
    /// Whether the menu bar icon is there to carry the reminder. Without it, Sparkle
    /// shows a found update in its own window, the only place left to see it.
    var menuBarVisible: () -> Bool = { true }
    /// The version of a found update that is not installed yet, as the menu shows it.
    private(set) var availableVersion: String?

    private var controller: SPUStandardUpdaterController?
    private var started = false

    static func make() -> AppUpdater? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty else { return nil }
        return AppUpdater()
    }

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                  userDriverDelegate: self)
    }

    /// Starts the scheduler (and, on the second launch, Sparkle's one-time question).
    /// Held back until setup is done, so neither lands on top of the permission window.
    func start() {
        guard !started, let controller else { return }
        started = true
        controller.startUpdater()
        onChange?()
    }

    var isStarted: Bool { started }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            onChange?()
        }
    }

    /// Looks for an update now, or brings a found one forward, in Sparkle's window.
    func checkForUpdates() {
        guard started, let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Runs a scheduled check now, as the daily one would: a found update goes to the
    /// menu and Settings, not into a window.
    func checkInBackground() {
        guard started, let controller else { return }
        controller.updater.checkForUpdatesInBackground()
    }

    // MARK: SPUUpdaterDelegate

    /// No system profile, even if a future Sparkle offered one by default.
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    // MARK: Reminders

    fileprivate func found(_ update: SUAppcastItem) {
        availableVersion = Self.label(for: update)
        onChange?()
    }

    fileprivate func sessionEnded() {
        availableVersion = nil
        onChange?()
    }

    /// "1.4.0"; dev builds share one short version, so they add the build number.
    private static func label(for update: SUAppcastItem) -> String {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let display = update.displayVersionString
        return display == current ? "\(display) (\(update.versionString))" : display
    }
}

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        !menuBarVisible()
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        found(update)
    }

    func standardUserDriverWillFinishUpdateSession() {
        sessionEnded()
    }
}
#else
/// The stub for builds without Sparkle; `make()` never returns one.
@MainActor
final class AppUpdater: NSObject {
    var onChange: (() -> Void)?
    var menuBarVisible: () -> Bool = { true }
    let availableVersion: String? = nil
    static func make() -> AppUpdater? { nil }
    func start() {}
    var isStarted: Bool { false }
    var automaticallyChecks: Bool {
        get { false }
        set {}
    }
    func checkForUpdates() {}
    func checkInBackground() {}
}
#endif
