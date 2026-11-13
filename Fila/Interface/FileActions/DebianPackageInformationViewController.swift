import FilaBackendUI
import SnapKit
import Then
import UIKit

/// The existing grouped form cells and sheet; packing owns all file writes.
final class DebianPackageInformationViewController: UITableViewController {
    private enum Section: Int, CaseIterable { case plugin, version, changes }
    private enum Row { case package, architecture, summary, icon, version, date, changes }
    private var information: DebianPackageInformation
    private let confirm: (String) -> Void
    private let changes = UITextView().then {
        $0.font = .preferredFont(forTextStyle: .body)
        $0.adjustsFontForContentSizeCategory = true
        $0.backgroundColor = .clear
        $0.autocorrectionType = .no
        $0.smartQuotesType = .no
        $0.smartDashesType = .no
        $0.keyboardDismissMode = .interactive
    }

    init(information: DebianPackageInformation, confirm: @escaping (String) -> Void) {
        self.information = information
        self.confirm = confirm
        super.init(style: .insetGrouped)
        title = String(localized: "Pack Debian Package")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) },
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Cancel")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Pack"), style: .done, target: self, action: #selector(commit),
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func present(from presenter: UIViewController, information: DebianPackageInformation, confirm: @escaping (String) -> Void) {
        let form = DebianPackageInformationViewController(information: information, confirm: confirm)
        presenter.presentAsSheet(UINavigationController(rootViewController: form))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(FormFieldCell.self, forCellReuseIdentifier: "field")
        tableView.keyboardDismissMode = .interactive
        changes.text = information.changes
        changes.accessibilityLabel = String(localized: "What's New")
    }

    private func rows(_ section: Int) -> [Row] {
        switch Section(rawValue: section) {
        case .plugin: [.package, .architecture, .summary, .icon]
        case .version: [.version, .date]
        case .changes: [.changes]
        case nil: []
        }
    }

    override func numberOfSections(in _: UITableView) -> Int { Section.allCases.count }
    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int { rows(section).count }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .plugin: String(localized: "Plugin Information")
        case .version: String(localized: "Version Information")
        case .changes: String(localized: "What's New")
        case nil: nil
        }
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .plugin: String(localized: "The icon link is optional. It must point to a public image, not a local file.")
        case .changes: String(localized: "Press Return for each update. Wrapped text stays in the same update. Information is saved to control before packing; the payload is kept unchanged.")
        default: nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows(indexPath.section)[indexPath.row]
        if row == .changes {
            let cell = UITableViewCell()
            cell.selectionStyle = .none
            cell.contentView.addSubview(changes)
            changes.snp.makeConstraints { make in
                make.edges.equalTo(cell.contentView.layoutMarginsGuide)
                make.height.equalTo(160)
            }
            return cell
        }
        if row == .summary {
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            var content = UIListContentConfiguration.valueCell()
            content.text = String(localized: "Description")
            let summary = information.descriptionText.components(separatedBy: "\n")[0]
            content.secondaryText = summary.isEmpty ? String(localized: "Required") : summary
            content.textProperties.numberOfLines = 1
            content.secondaryTextProperties.numberOfLines = 1
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        if row == .architecture || row == .package && information.hasPackageIdentifier {
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            var content = UIListContentConfiguration.valueCell()
            content.text = row == .architecture ? String(localized: "Architecture") : String(localized: "Package Identifier")
            content.secondaryText = row == .architecture ? information.architecture : information.package
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "field", for: indexPath) as! FormFieldCell
        cell.configure(field(row)) { [weak self] text in
            guard let self else { return }
            switch row {
            case .package: information.package = text
            case .icon: information.icon = text
            case .version: information.version = text
            case .date: information.date = text
            default: break
            }
        }
        return cell
    }

    private func field(_ row: Row) -> FormFieldCell.Configuration {
        switch row {
        case .package: .init(title: String(localized: "Package Identifier"), placeholder: "com.example.package", text: information.package)
        case .icon: .init(title: String(localized: "Icon Link"), placeholder: String(localized: "Optional"), text: information.icon, keyboard: .URL)
        case .version: .init(title: String(localized: "Version"), placeholder: String(localized: "Required"), text: information.version)
        case .date: .init(title: String(localized: "Release Date"), placeholder: "YYYY-MM-DD", text: information.date, keyboard: .numbersAndPunctuation)
        default: .init(title: "", placeholder: "", text: "")
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if rows(indexPath.section)[indexPath.row] == .summary {
            view.endEditing(true)
            let editor = DebianDescriptionViewController(text: information.descriptionText) { [weak self] text in
                guard let self else { return }
                information.descriptionText = text
                tableView.reloadRows(at: [indexPath], with: .none)
            }
            presentAsSheet(UINavigationController(rootViewController: editor))
            return
        }
        (tableView.cellForRow(at: indexPath) as? FormFieldCell)?.beginEditing()
    }

    @objc private func commit() {
        view.endEditing(true)
        information.changes = changes.text ?? ""
        do {
            let text = try information.controlText()
            dismiss(animated: true) { self.confirm(text) }
        } catch {
            presentMessage(String(localized: "The Package Was Not Built"), message: error.localizedDescription)
        }
    }
}
