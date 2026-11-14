import AppKit
import os
import Sparkle

/// Sparkle updater, started only when `SUPublicEDKey` is a base64 Ed25519 public key (32 bytes); an empty or
/// malformed key would show Sparkle's misconfiguration alert. Until then "Check for Updates…" stays disabled.
/// Automated DEBUG launches (`-HistqStateDir`, `-HistqBackground YES`) never start it, so a QA run shows no Sparkle
/// window and makes no update request.
@MainActor
final class Updater {
    private(set) var canCheckForUpdates = false

    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                               userDriverDelegate: nil)

    func start() {
        let logger = Logger(subsystem: "com.math2it.histq", category: "Updater")
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
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
