import AppKit
import Observation
import os
import Sparkle

/// Sparkle updater, started only when `SUPublicEDKey` is a base64 Ed25519 public key (32 bytes); an empty or
/// malformed key would show Sparkle's misconfiguration alert. Until then "Check for Updates…" stays disabled.
/// Automated DEBUG launches (`-HistqStateDir`, `-HistqBackground YES`) never start it, so a QA run shows no Sparkle
/// window and makes no update request.
///
/// Background checks (at launch, then every `SUScheduledCheckInterval`) never pop Sparkle's dialog: with
/// `SUAutomaticallyUpdate` they download and prepare the update silently, then set `availableUpdateVersion`, which
/// shows the toolbar's Update button and turns the app menu's item into "Install Update and Relaunch"; both install it
/// and relaunch at once (Sparkle also installs it when the app quits). An update Sparkle does not download silently (a
/// major upgrade, an informational one) sets it when Sparkle would show it, the item reads "Update to Histq
/// <version>…", and the button and the item open Sparkle's dialog (shown at once when no window has the button); it is
/// cleared when that update session ends. The menu reads the flags each time it opens; the toolbar observes
/// `updateAvailable`.
@MainActor
@Observable
final class Updater: NSObject {
    private(set) var canCheckForUpdates = false
    /// The update's version, set once a click can act on it, not when it is found: while it downloads, Sparkle's
    /// session is busy and `checkForUpdates` would do nothing.
    private(set) var availableUpdateVersion: String?
    var updateAvailable: Bool { availableUpdateVersion != nil }
    /// Whether an open window's toolbar has the Update button (a customized toolbar may lack it). Set by the app
    /// delegate; without the button Sparkle shows its own dialog.
    @ObservationIgnored var hasUpdateButton: (() -> Bool)?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    /// Installs the silently downloaded update and relaunches the app; nil until it is ready.
    @ObservationIgnored private var installNow: (() -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                  userDriverDelegate: self)
    }

    /// The app menu's item for `checkForUpdates`.
    var menuTitle: String {
        if installNow != nil { return "Install Update and Relaunch" }
        guard let availableUpdateVersion else { return "Check for Updates…" }
        return "Update to Histq \(availableUpdateVersion)…"
    }

    func start() {
        let logger = Logger(subsystem: "com.math2it.histq", category: "Updater")
        #if DEBUG
        // QA of the Update button, also in an automated launch.
        if ProcessInfo.processInfo.arguments.contains("-HistqFakeUpdate") { availableUpdateVersion = "9.9.9" }
        // Off unless asked: Debug and Release share the bundle id, and a Debug build left running downloads the
        // release and keeps Sparkle's installer, which is per bundle id, waiting for it to quit, so every other
        // Histq's update fails until then.
        guard ProcessInfo.processInfo.arguments.contains("-HistqSparkle") else {
            return logger.notice("Updater off: Debug build without -HistqSparkle")
        }
        #endif
        // Both flags read as absent in Release.
        guard !AppState.isStateDirMode, !AppState.isBackgroundLaunch else {
            return logger.notice("Updater off: automated launch")
        }
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Data(base64Encoded: key)?.count == 32 else {
            return logger.notice("Updater off: SUPublicEDKey is not a base64 32-byte EdDSA public key")
        }
        controller.startUpdater()
        canCheckForUpdates = true
        if controller.updater.automaticallyChecksForUpdates { controller.updater.checkForUpdatesInBackground() }
    }

    /// Installs a downloaded update without any dialog (the app quits and relaunches), else Sparkle's check.
    func checkForUpdates() {
        if let installNow {
            installNow()
            return
        }
        guard canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

extension Updater: SPUUpdaterDelegate {
    /// Taking the install stalls Sparkle's update cycle until the app relaunches, so no later check runs.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        availableUpdateVersion = item.displayVersionString
        return true
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableUpdateVersion = nil
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        if choice == .skip { availableUpdateVersion = nil }
    }
}

extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// The Update button and the menu item stand in for Sparkle's dialog on background checks; Sparkle shows it when
    /// no window shows the button.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        !(hasUpdateButton?() ?? false)
    }

    /// An update found by a background check, which the Update button and the menu item show.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        availableUpdateVersion = update.displayVersionString
    }

    /// After an install, a skip, "Remind Me Later" or an error. Silent downloads (`installNow`) run no such session.
    func standardUserDriverWillFinishUpdateSession() {
        if availableUpdateVersion != nil { availableUpdateVersion = nil }
    }
}
