import FilaLog
import UIKit

/// Read the live preferences on every opening, including after a change in
/// the retained General page or after the backend handshake.
@MainActor
enum GeneralSettingsMenu {
    static func menu(from presenter: UIViewController) -> UIMenu {
        UIMenu(title: String(localized: "General"), children: [
            UIDeferredMenuElement.uncached { [weak presenter] completion in
                guard let presenter else { return completion([]) }
                completion(elements(from: presenter))
            },
        ])
    }

    private static func elements(from presenter: UIViewController) -> [UIMenuElement] {
        let preferences = AppPreferences.shared
        let session = FileSession.shared
        let selected = preferences.launchLocation
        let choose: (LaunchLocation) -> Void = { preferences.launchLocation = $0 }
        let fixed: [UIMenuElement] = [LaunchLocation.root, .home, .lastVisited].map { location in
            UIAction(
                title: GeneralSettingsViewController.name(of: location),
                state: selected == location ? .on : .off,
            ) { _ in choose(location) }
        }
        let launch = UIMenu(title: String(localized: "Open at Launch"), children: FilaMenu.groups(
            fixed,
            FilaMenu.collections { path in choose(.folder(path)) },
        ))
        let places: [UIMenuElement] = GeneralSettingsViewController.offeredPresets().map { preset in
            toggle(
                GeneralSettingsViewController.name(of: preset),
                enabled: session.local.isPresetEnabled(preset),
            ) { enabled in
                do { try session.local.setPreset(preset, enabled: enabled) }
                catch { FilaLog.error("preset not saved: \(error)") }
            }
        }
        let trashAvailable = FileActions.backendHasTrash
        return [
            launch,
            toggle(String(localized: "Show Hidden Files"), enabled: session.showsHidden) {
                session.setShowsHidden($0)
            },
            toggle(String(localized: "Remember Recents"), enabled: preferences.recordsRecents) {
                preferences.recordsRecents = $0
            },
            toggle(
                String(localized: "Use Trash"),
                enabled: preferences.usesTrash && trashAvailable,
                available: trashAvailable,
            ) { preferences.usesTrash = $0 },
            toggle(String(localized: "Find Script Interpreters"), enabled: preferences.redirectsScriptInterpreters) {
                preferences.redirectsScriptInterpreters = $0
            },
            UIMenu(title: String(localized: "Places"), children: FilaMenu.groups(
                places,
                [SettingsMenu.action(String(localized: "Reorder Places…"), from: presenter) {
                    GeneralSettingsViewController()
                }],
            )),
        ]
    }

    private static func toggle(
        _ title: String,
        enabled: Bool,
        available: Bool = true,
        update: @escaping (Bool) -> Void,
    ) -> UIAction {
        UIAction(title: title, attributes: available ? [] : .disabled, state: enabled ? .on : .off) { _ in
            guard available else { return }
            update(!enabled)
            NotificationCenter.default.post(name: .filaPreferencesChanged, object: nil)
        }
    }
}
