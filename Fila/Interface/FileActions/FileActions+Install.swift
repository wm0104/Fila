import AlertController
import Darwin
import FilaBackendKit
import FilaBackendUI
import FilaProtocol
import FilaTerminal
import UIKit

extension FileActions {
    /// One Install… entry, routed by format, each behind a card that says what
    /// is about to happen. A `.deb` runs the bootstrap's `dpkg -i` on a
    /// terminal as root, so it needs the daemon and the Run setting. Both app
    /// formats prefer a targeted TrollStore handoff. When that is unavailable,
    /// TIPA keeps Open With and IPA keeps its existing system-installer route.
    func installAction(_ path: String, node: FileNode, confirm: @escaping (@escaping () -> Void) -> Void) -> UIAction? {
        guard node.kind == .regular else { return nil }
        let install: () -> Void
        switch (path as NSString).pathExtension.lowercased() {
        case "deb":
            guard SystemCapabilities.runsPrograms else { return nil }
            install = { [self] in promptInstallPackage(path) }
        case "tipa":
            install = { [self] in promptTrollStore(path) { self.share([path]) } }
        case "ipa":
            // A sandboxed build has no InstallCoordination entitlement and
            // would copy the whole package only to be refused; the handshake
            // says which build this is, so the entry waits for it.
            guard let backend = session.hello?.backend, backend != .local(reach: .container),
                  let applications = SystemCapabilities.applications else { return nil }
            install = { [self] in promptTrollStore(path) { self.promptInstallApp(path, applications: applications) } }
        default:
            return nil
        }
        return UIAction(
            title: String(localized: "Install…"),
            image: UIImage(systemName: "arrow.down.app"),
        ) { _ in confirm(install) }
    }

    private func promptTrollStore(_ path: String, fallback: @escaping () -> Void) {
        let name = (path as NSString).lastPathComponent
        confirmDestruction(
            title: String(localized: "Open in TrollStore?"),
            message: String(localized: "Opens a copy of “\(name)” in TrollStore. The original file is kept."),
            confirm: String(localized: "Open"),
        ) {
            Task { if await !self.openInTrollStore(path) { fallback() } }
        }
    }

    /// Deliver into the receiver's Inbox first: TrollStore may still be
    /// reading after Fila exits or sweeps its own temporary workspace.
    private func openInTrollStore(_ path: String) async -> Bool {
        guard let applications = SystemCapabilities.applications,
              let location = await applications.locate(bundleIdentifier: "com.opa334.TrollStore"),
              let dataPath = location.dataPath else { return false }
        guard !Self.appInstallInFlight else {
            FeedbackAlert.show(String(localized: "Installation in Progress"), message: String(localized: "Wait for the current installation to finish, then try again."))
            return true
        }
        Self.appInstallInFlight = true
        defer { Self.appInstallInFlight = false }
        do {
            let inbox = try await session.perform { try await TrollStoreInbox.prepare(dataPath: dataPath, access: $0) }
            let staged = try await session.stage(path)
            defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            let unique = staged.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "." + (path as NSString).pathExtension.lowercased())
            try FileManager.default.moveItem(at: staged, to: unique)
            guard await FileDelivery.deliver([.local(unique.path)], into: .local(inbox), mode: .copy, from: activePresenter) else { return true }
            let delivered = URL(fileURLWithPath: inbox).appendingPathComponent(unique.lastPathComponent)
            switch await applications.openInTrollStore(packageAt: delivered) {
            case .opened:
                return true
            case .unavailable:
                // No document was sent. Only this unique delivered copy is ours.
                try await session.perform { try await $0.remove(delivered.path, directory: false, overrideGuard: false) }
                return false
            case .failed, .unanswered:
                FeedbackAlert.show(
                    String(localized: "Cannot Install"),
                    message: String(localized: "TrollStore did not confirm opening the file. The copy is kept at \(delivered.path). Check TrollStore before trying again."),
                )
                return true
            }
        } catch { report(error); return true }
    }

    /// Reads the package's identity first, and refuses Fila's own: its postinst
    /// restarts `filad`, and a stopping daemon hangs up every terminal it
    /// spawned — dpkg included, between unpack and configure. That package
    /// goes through the system package manager or the device updater, never a
    /// terminal this daemon owns.
    private static var packagePreparations = 0

    private func promptInstallPackage(_ path: String) {
        let name = (path as NSString).lastPathComponent
        Self.packagePreparations += 1
        Task {
            defer { Self.packagePreparations -= 1 }
            let staged: URL
            do { staged = try await session.stage(path) }
            catch { report(error); return }
            let cleanup: @MainActor @Sendable () -> Void = { [self] in
                do { try FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
                catch { report(error) }
            }
            do {
                let manifest = try await DebianPackage.manifest(ofDebAt: staged.path, session: session)
                guard manifest.package != Bundle.main.bundleIdentifier else {
                    throw ViewerFailure.unsupportedContent(String(localized: "“\(name)” is Fila itself and cannot be installed from here. Install it with your package manager."))
                }
                guard let presenter = activePresenter else { cleanup(); return }
                let alert = AlertViewController(
                    title: String.LocalizationValue("Install Package?"),
                    message: String.LocalizationValue("Installs “\(name)” as root with dpkg. A faulty package can damage the system environment or leave the device unable to start. This cannot be undone."),
                ) { context in
                    context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose { cleanup() } }
                    context.addAction(title: String.LocalizationValue("Install"), attribute: .accent) {
                        context.dispose {
                            if !self.openTerminal(
                                .installPackage(path: staged.path),
                                user: .root,
                                onProcessExit: cleanup,
                            ) {
                                cleanup()
                            }
                        }
                    }
                }
                presenter.present(alert, animated: true)
            } catch { cleanup(); report(error) }
        }
    }

    /// Keep package confirmations and installs serial across all file screens.
    /// Different paths can contain packages for the same application.
    private static var appInstallInFlight = false

    static var hasActiveInstallation: Bool { appInstallInFlight || packagePreparations > 0 }

    /// Stages the copy first — the installer consumes what it is handed — and
    /// reads the manifest from that copy, so the card, the install and any
    /// cleanup all describe the same bytes even if the original is replaced
    /// while the card is up.
    private func promptInstallApp(_ path: String, applications: any ApplicationCapability) {
        guard !Self.appInstallInFlight else {
            FeedbackAlert.show(
                String(localized: "Installation in Progress"),
                message: String(localized: "Wait for the current installation to finish, then try again."),
            )
            return
        }
        Self.appInstallInFlight = true
        Task {
            let staged: URL
            let manifest: PackageManifest
            do {
                (staged, manifest) = try await withInstallProgress(String(localized: "Reading App…"), cancellable: true) {
                    let staged = try await self.session.stage(path)
                    do {
                        let manifest = try await applications.manifest(ofPackageAt: staged)
                        // A Cancel that came while the manifest was read still
                        // cancels, and the staged copy must not outlive it.
                        try Task.checkCancellation()
                        return (staged, manifest)
                    } catch {
                        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                        throw error
                    }
                }
            } catch {
                Self.appInstallInFlight = false
                report(error)
                return
            }
            guard let presenter = activePresenter else {
                try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                Self.appInstallInFlight = false
                return
            }
            let alert = AlertViewController(
                title: String.LocalizationValue("Install App?"),
                message: String.LocalizationValue("The system installer will install “\(manifest.displayName)” (\(manifest.bundleIdentifier)), replacing any app with the same identifier. Apps not signed for this device require AppSync Unified."),
            ) { context in
                context.addAction(title: String.LocalizationValue("Cancel")) {
                    context.dispose {
                        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                        Self.appInstallInFlight = false
                    }
                }
                context.addAction(title: String.LocalizationValue("Install"), attribute: .accent) {
                    context.dispose {
                        Task { await self.installApp(path, staged: staged, manifest: manifest, applications: applications) }
                    }
                }
            }
            presenter.present(alert, animated: true)
        }
    }

    /// A failure does not establish ownership of anything now registered under
    /// the identifier. The system or another installer may have changed it, so
    /// uninstall remains an explicit user action in Applications.
    private func installApp(
        _ path: String, staged: URL, manifest: PackageManifest, applications: any ApplicationCapability,
    ) async {
        // Only a cancelled wait comes back empty, and installd may still be
        // reading the package then: that is the unanswered case. installd
        // cannot be stopped, so the card offers Continue and no Cancel.
        let outcome = await (try? withInstallProgress(String(localized: "Installing App…"), cancellable: false) {
            await applications.install(packageAt: staged)
        }) ?? .timedOut
        // An unanswered request may still be reading its source. Preserve the
        // workspace and keep further requests disabled for this session.
        switch outcome {
        case .timedOut: break
        default:
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            Self.appInstallInFlight = false
        }
        switch outcome {
        case .installed:
            Toast.show(String(localized: "App installed"))
        case .unsupported:
            reportInstallRefusal(
                path,
                message: String(localized: "Fila cannot use the system installer. Open “\(manifest.displayName)” with another installer."),
            )
        case .timedOut:
            report(NSError(
                domain: "ApplicationInstaller",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "The installer is still working. Check Applications before trying again.",
                    ),
                ],
            ))
        case let .failed(domain, code, message):
            if outcome.isSignatureRefusal {
                reportInstallRefusal(
                    path,
                    message: String(localized: "The signature of “\(manifest.displayName)” was rejected. Install AppSync Unified on this device or open the file in TrollStore."),
                )
            } else {
                report(NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message]))
            }
        }
    }

    /// The work runs whether or not there is a screen left to put the card on.
    private func withInstallProgress<T: Sendable>(
        _ title: String,
        cancellable: Bool,
        _ operation: @escaping @MainActor () async throws -> T,
    ) async throws -> T {
        guard let presenter = activePresenter else { return try await operation() }
        return try await ProgressCard.run(
            title: title,
            message: String(localized: "Keep Fila open until this finishes."),
            cancellable: cancellable,
            from: presenter,
        ) { _ in try await operation() }
    }

    /// A refusal with a way out: the same share sheet the `.tipa` route uses,
    /// where TrollStore (or another installer) is one tap away.
    private func reportInstallRefusal(_ path: String, message: String) {
        guard let presenter = activePresenter else {
            FeedbackAlert.show(String(localized: "Cannot Install"), message: message)
            return
        }
        let alert = AlertViewController(
            title: String.LocalizationValue("Cannot Install"),
            message: .init(message),
        ) { context in
            context.addAction(title: String.LocalizationValue("Cancel")) {
                context.dispose()
            }
            context.addAction(title: String.LocalizationValue("Open With…"), attribute: .accent) {
                context.dispose { self.share([path]) }
            }
        }
        presenter.present(alert, animated: true)
    }
}
