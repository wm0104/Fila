import UIKit

/// The same feature screens as the overview, reached directly from More.
@MainActor
enum SettingsMenu {
    static func menu(from presenter: UIViewController) -> UIMenu {
        var children: [UIMenuElement] = [
            GeneralSettingsMenu.menu(from: presenter),
            action(String(localized: "Tasks"), from: presenter) { TransfersViewController() },
            action(String(localized: "Log"), from: presenter) {
                let log = LogViewController()
                await log.loadEverything()
                return log
            },
            action(String(localized: "File Sharing"), from: presenter) { FileSharingViewController() },
        ]
        if !BackendComposition.registry.connectionSetups.isEmpty {
            children.append(action(String(localized: "Servers"), from: presenter) { ServersSettingsViewController() })
        }
        children.append(contentsOf: [
            UIAction(title: String(localized: "Version") + " " + SettingsViewController.appVersion, attributes: .disabled) { _ in },
            action(String(localized: "Details"), from: presenter) { SettingsViewController.details() },
            action(String(localized: "Open Source Licenses"), from: presenter) { LicensesViewController() },
        ])
        return UIMenu(title: String(localized: "Settings"), image: UIImage(systemName: "gearshape"), children: children)
    }

    static func action(
        _ title: String,
        from presenter: UIViewController,
        screen: @escaping @MainActor () async -> UIViewController,
    ) -> UIAction {
        UIAction(title: title) { [weak presenter] _ in
            guard let presenter, let root = presenter.view.window?.rootViewController else { return }
            Task { @MainActor in
                let controller = await screen()
                // Re-resolve after loading the log and after the native menu dismisses.
                TopPresenter.whenReady(from: root) { top in
                    let shown = (top as? UINavigationController)?.viewControllers ?? [top]
                    guard !shown.contains(where: { type(of: $0) == type(of: controller) }) else { return }
                    let navigation = UINavigationController(rootViewController: controller)
                    // Keep the screen's existing controls (including Tasks' Clear).
                    if controller.navigationItem.leftBarButtonItems?.isEmpty != false {
                        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
                            image: UIImage(systemName: "xmark"),
                            primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) },
                        )
                        controller.navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Close")
                    }
                    top.presentAsFormSheet(navigation)
                }
            }
        }
    }
}
