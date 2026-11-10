import AlertController
import Darwin
import FilaClient
import FilaProtocol
import FilaTerminal
import UIKit

/// Back up into the invoking browser's folder; restore only by opening a file.
@MainActor
enum ConfigurationBackupController {
    private static var busy = false
    private(set) static var isExiting = false
    private static var startupFailure: Error?
    private static let pendingKey = "wiki.qaq.fila.configuration.restorePending"

    static func action(directory: String, from presenter: UIViewController) -> UIAction {
        UIAction(
            title: String(localized: "Back Up Configuration"),
            image: UIImage(systemName: "square.and.arrow.up"),
            attributes: FileActions.isTrash(directory) ? .disabled : [],
        ) { [weak presenter] _ in
            guard let presenter else { return }
            backup(in: directory, from: presenter)
        }
    }

    private static func backup(in directory: String, from presenter: UIViewController) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let data = try ConfigurationBackup.capture()
                let file = try await ConfigurationBackupFiles.export(data, into: directory)
                TopPresenter.whenReady(from: presenter.view.window?.rootViewController) { top in
                    top.presentMessage(
                        String(localized: "Configuration Backed Up"),
                        message: String(localized: "The backup contains settings and favorites, not passwords or file contents.") + "\n\n" + file.path,
                    )
                }
            } catch {
                report(error, from: presenter)
            }
        }
    }

    static func restore(path: String, from presenter: UIViewController) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            let url = URL(fileURLWithPath: path)
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            do {
                // Nonblocking open also refuses a pipe disguised as a backup.
                let descriptor = try await FileSession.shared.perform(retryOnDisconnect: true) {
                    try await $0.open(path, flags: O_RDONLY | O_NONBLOCK)
                }
                let data = try await Task.detached {
                    try DescriptorIO.readAndClose(descriptor, limit: ConfigurationBackup.maximumFileSize + 1)
                }.value
                _ = try ConfigurationBackup.decode(data)
                TopPresenter.whenReady(from: presenter.view.window?.rootViewController) { top in
                    guard allowRestore(from: top) else { busy = false; return }
                    Task { @MainActor in
                        let confirmed = await CardQuestion.ask(whenGone: false, from: top) { reply in
                            AlertViewController(
                                title: String.LocalizationValue("Restore Configuration"),
                                message: String.LocalizationValue("Replace settings and favorites with this backup? Files, passwords and servers will not be changed. Browsing history is not backed up; restoring a disabled history setting clears recent entries. Fila must quit and reopen to apply it."),
                            ) { context in
                                context.addAction(title: String.LocalizationValue("Cancel")) { reply(context, false) }
                                context.addAction(title: String.LocalizationValue("Restore"), attribute: .accent) { reply(context, true) }
                            }
                        }
                        guard confirmed else { busy = false; return }
                        stage(data, from: top)
                    }
                }
            } catch {
                busy = false
                report(error, from: presenter)
            }
        }
    }

    private static func stage(_ data: Data, from presenter: UIViewController) {
        guard allowRestore(from: presenter) else { busy = false; return }
        guard !UserDefaults.standard.bool(forKey: pendingKey) else {
            busy = false
            report(FilaFailure(errno: EBUSY), from: presenter)
            return
        }
        Task { @MainActor in
            do {
                try await Task.detached { try ConfigurationBackupFiles.stage(data) }.value
                TopPresenter.whenReady(from: presenter.view.window?.rootViewController) { top in
                    Task { @MainActor in
                        let confirmed = await CardQuestion.ask(whenGone: false, from: top) { reply in
                            AlertViewController(
                                title: String.LocalizationValue("Configuration Restored"),
                                message: String.LocalizationValue("Tap OK to quit Fila, then open it again to apply the restored configuration."),
                            ) { context in
                                context.addAction(title: String.LocalizationValue("OK"), attribute: .accent) { reply(context, true) }
                            }
                        }
                        guard confirmed, allowRestore(from: top) else {
                            // An unconfirmed prepared snapshot is never applied at startup.
                            try? ConfigurationBackupFiles.removePrepared()
                            busy = false
                            return
                        }
                        do {
                            try ConfigurationBackupFiles.arm()
                            UserDefaults.standard.set(true, forKey: pendingKey)
                            guard UserDefaults.standard.synchronize() else {
                                UserDefaults.standard.removeObject(forKey: pendingKey)
                                try? ConfigurationBackupFiles.removePending()
                                throw ConfigurationBackupFailure.persistenceFailed
                            }
                        }
                        catch {
                            busy = false
                            report(error, from: top)
                            return
                        }
                        isExiting = true
                        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                            scene.windows.forEach { $0.isUserInteractionEnabled = false }
                        }
                        QuietExit.run {
                            (UIApplication.shared.delegate as? AppDelegate)?.applicationWillTerminate(.shared)
                        }
                    }
                }
            } catch {
                busy = false
                report(error, from: presenter)
            }
        }
    }

    /// Apply before FileSession or any cached preferences are constructed.
    static func applyPendingAtLaunch() {
        // Normal launches do no restore-directory I/O. Consume the explicit
        // confirmation first so a rejected snapshot cannot produce a launch loop.
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        guard UserDefaults.standard.synchronize() else {
            startupFailure = ConfigurationBackupFailure.persistenceFailed
            return
        }
        do {
            guard let data = try ConfigurationBackupFiles.pending() else { throw CocoaError(.fileReadNoSuchFile) }
            guard let domain = Bundle.main.bundleIdentifier else { throw CocoaError(.fileReadCorruptFile) }
            let backup = try ConfigurationBackup.decode(data)
            try backup.restore(defaults: .standard, domainName: domain)
            try ConfigurationBackupFiles.removePending()
        } catch {
            startupFailure = error
            // Do not retry a failed/corrupt snapshot on every launch.
            try? ConfigurationBackupFiles.removePending()
        }
    }

    static func reportStartupFailure() {
        guard let failure = startupFailure else { return }
        startupFailure = nil
        TopPresenter.whenReady { report(failure, from: $0) }
    }

    private static func report(_ error: Error, from presenter: UIViewController) {
        TopPresenter.whenReady(from: presenter.view.window?.rootViewController) { top in
            let reason: String
            switch error {
            case ConfigurationBackupFailure.tooLarge:
                reason = String(localized: "The configuration backup is too large. The maximum size is 1 MB.")
            case ConfigurationBackupFailure.persistenceFailed, ConfigurationBackupFailure.rollbackFailed:
                reason = String(localized: "The restored settings could not be saved. Keep your backup and try again.")
            case is ConfigurationBackupFailure, is DecodingError:
                reason = String(localized: "This is not a valid or supported Fila configuration backup. No backup settings were applied.")
            default:
                reason = FailureMessage.text(for: error)
            }
            top.presentMessage(String(localized: "Configuration Backup Failed"), message: reason)
        }
    }

    private static func allowRestore(from presenter: UIViewController) -> Bool {
        if FileSharingServer.shared.requiresRestartBeforeConfigurationRestore {
            presenter.presentMessage(
                String(localized: "Configuration Restore Is Not Available"),
                message: String(localized: "File sharing was used in this session. Finish transfers, stop sharing and reopen Fila before restoring configuration."),
            )
            return false
        }
        guard !FileSession.shared.operations.hasActiveWork, !FileActions.hasActiveInstallation,
              !FileActions.hasSharePreparation, FileSession.shared.activeStagingCount == 0,
              !ProgressCard.hasActiveWork,
              !FileSharingServer.shared.isRunning, !FileSharingServer.shared.isStarting,
              !UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).contains(where: { window in
                    window.rootViewController.map(hasProtectedWork) ?? false
                })
        else {
            presenter.presentMessage(
                String(localized: "Configuration Restore Is Not Available"),
                message: String(localized: "Finish file tasks, stop file sharing, and save and close editors, installers and terminals in every window before restoring configuration."),
            )
            return false
        }
        return true
    }

    private static func hasProtectedWork(_ controller: UIViewController) -> Bool {
        // A retained editor may be in a hidden tab; checking only the top page loses it.
        if controller is ViewerContainerViewController || controller is ControlEditorViewController
            || controller is TerminalViewController || controller is OperationCoverViewController
            || controller is UIActivityViewController || controller is AlertViewController
            || controller.isModalInPresentation
        {
            return true
        }
        if let navigation = controller as? TabNavigationController,
           navigation.isTransitionPending || navigation.pendingPushes.contains(where: hasProtectedWork)
        {
            return true
        }
        if let tabs = controller as? TabContainerViewController,
           tabs.retainedNavigations.contains(where: hasProtectedWork)
        {
            return true
        }
        if controller.children.contains(where: hasProtectedWork) { return true }
        return controller.presentedViewController.map(hasProtectedWork) ?? false
    }
}
