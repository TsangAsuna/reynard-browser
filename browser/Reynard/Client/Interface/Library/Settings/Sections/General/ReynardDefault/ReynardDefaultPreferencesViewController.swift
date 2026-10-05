//
//  ReynardDefaultPreferencesViewController.swift
//  Reynard
//
//  Created by TsangAsuna on 5/10/26.
//

import UIKit

// Bridge to the preference suite shared with the ReynardDefault tweak:
// SpringBoard reads "redirect.<bundle id>" keys from the same domain and
// reroutes the matching apps' web link opens to Reynard.
enum ReynardDefaultPrefsBridge {
    static let domain = "com.guacforlife.reynarddefaultprefs"
    static let defaultRedirectBundleID = "com.apple.mobilesafari"
    private static let keyPrefix = "redirect."

    static func redirectEnabled(for bundleID: String) -> Bool {
        guard let value = CFPreferencesCopyAppValue(key(for: bundleID) as CFString, domain as CFString) else {
            // Out-of-the-box behavior: links other apps hand to Safari land in
            // Reynard; every other app behaves normally until checked.
            return bundleID == defaultRedirectBundleID
        }
        return (value as? Bool) ?? false
    }

    static func setRedirect(_ enabled: Bool, for bundleID: String) {
        let value: CFBoolean = enabled ? kCFBooleanTrue : kCFBooleanFalse
        CFPreferencesSetValue(
            key(for: bundleID) as CFString,
            value,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        CFPreferencesAppSynchronize(domain as CFString)
    }

    static func redirectBundleIDs() -> [String] {
        guard let keyList = CFPreferencesCopyKeyList(
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [String] else {
            return []
        }

        return keyList.compactMap { key in
            guard key.hasPrefix(keyPrefix),
                  let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString),
                  (value as? Bool) ?? false else {
                return nil
            }
            return String(key.dropFirst(keyPrefix.count))
        }
    }

    static func removeAllRedirects() {
        for bundleID in redirectBundleIDs() {
            CFPreferencesSetValue(
                key(for: bundleID) as CFString,
                nil,
                domain as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
        }
        CFPreferencesAppSynchronize(domain as CFString)
    }

    private static func key(for bundleID: String) -> String {
        return keyPrefix + bundleID
    }
}

struct InstalledAppInfo {
    let bundleID: String
    let displayName: String
}

// Enumerates every installed application, including TrollStore installs, via
// the private LaunchServices workspace API (available to the unsandboxed
// jailbroken and TrollStore builds this feature targets).
enum InstalledAppList {
    static func fetch() -> [InstalledAppInfo] {
        let rawApplications = ReynardCopyInstalledApplications() as? [[String: String]] ?? []

        return rawApplications
            .compactMap { raw in
                guard let bundleID = raw["bundleID"], let displayName = raw["name"] else {
                    return nil
                }
                return InstalledAppInfo(bundleID: bundleID, displayName: displayName)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

final class ReynardDefaultPreferencesViewController: SettingsTableViewController {
    private enum Section: Int, CaseIterable {
        case apps
        case reset
    }

    private lazy var searchBar: UISearchBar = {
        let searchBar = UISearchBar(frame: .zero)
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.searchBarStyle = .minimal
        searchBar.placeholder = NSLocalizedString("Search Apps", comment: "")
        searchBar.delegate = self
        return searchBar
    }()

    private var installedApps: [InstalledAppInfo] = []
    private var displayedApps: [InstalledAppInfo] = []
    private var listFailed = false

    init() {
        super.init(style: .insetGrouped)
        title = NSLocalizedString("Default Browser Redirect", comment: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        let headerView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 52))
        headerView.addSubview(searchBar)
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: headerView.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: headerView.layoutMarginsGuide.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: headerView.layoutMarginsGuide.trailingAnchor),
            searchBar.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
        ])
        tableView.tableHeaderView = headerView

        reloadApps()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    // MARK: - Data

    private func reloadApps() {
        installedApps = InstalledAppList.fetch()
        listFailed = installedApps.isEmpty
        searchChanged()
    }

    private func searchChanged() {
        let term = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if term.isEmpty {
            displayedApps = installedApps
        } else {
            displayedApps = installedApps.filter {
                $0.displayName.lowercased().contains(term) || $0.bundleID.lowercased().contains(term)
            }
        }
        tableView.reloadData()
    }

    // MARK: - Table Data Source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let tableSection = Section(rawValue: section) else {
            return 0
        }

        switch tableSection {
        case .apps:
            return listFailed ? 1 : displayedApps.count
        case .reset:
            return listFailed ? 0 : 1
        }
    }

    override func sectionText(for section: Int) -> SettingsSectionText {
        guard let tableSection = Section(rawValue: section) else {
            return SettingsSectionText()
        }

        switch tableSection {
        case .apps:
            return SettingsSectionText(
                headerTitle: NSLocalizedString("Redirect Sources", comment: ""),
                footerTitle: NSLocalizedString(
                    "Checked apps hand the web links they open to Reynard instead of their own browser. Safari is checked by default. This per-app list only applies while the 'Redirect All Web Links' switch in system Settings is off; browser app launches are never redirected.",
                    comment: ""
                )
            )
        case .reset:
            return SettingsSectionText()
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let tableSection = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }

        switch tableSection {
        case .apps:
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            if listFailed {
                cell.textLabel?.text = NSLocalizedString("Unable to list installed apps", comment: "")
                cell.textLabel?.textColor = .secondaryLabel
                cell.isUserInteractionEnabled = false
                return cell
            }

            let app = displayedApps[indexPath.row]
            cell.textLabel?.text = app.displayName
            cell.detailTextLabel?.text = app.bundleID
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.detailTextLabel?.adjustsFontSizeToFitWidth = true
            cell.tintColor = view.tintColor
            cell.accessoryType = ReynardDefaultPrefsBridge.redirectEnabled(for: app.bundleID) ? .checkmark : .none
            return cell

        case .reset:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("Reset Selection", comment: "")
            cell.textLabel?.textColor = .systemRed
            cell.textLabel?.textAlignment = .center
            return cell
        }
    }

    // MARK: - Table Delegate

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let tableSection = Section(rawValue: indexPath.section) else {
            return false
        }

        switch tableSection {
        case .apps:
            return !listFailed
        case .reset:
            return true
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }

        guard let tableSection = Section(rawValue: indexPath.section) else {
            return
        }

        switch tableSection {
        case .apps:
            guard !listFailed, displayedApps.indices.contains(indexPath.row) else {
                return
            }
            let app = displayedApps[indexPath.row]
            let enabled = !ReynardDefaultPrefsBridge.redirectEnabled(for: app.bundleID)
            ReynardDefaultPrefsBridge.setRedirect(enabled, for: app.bundleID)
            tableView.reloadRows(at: [indexPath], with: .none)

        case .reset:
            confirmReset()
        }
    }

    private func confirmReset() {
        AlertPresenter.show(
            title: NSLocalizedString("Reset Redirect Selection?", comment: ""),
            message: NSLocalizedString("Every app will hand links to its own browser again, and Safari reverts to the default redirect.", comment: ""),
            buttons: [
                AlertPresenter.Button(title: NSLocalizedString("Cancel", comment: ""), style: .cancel),
                AlertPresenter.Button(title: NSLocalizedString("Reset", comment: ""), style: .destructive) {
                    ReynardDefaultPrefsBridge.removeAllRedirects()
                    self.tableView.reloadData()
                },
            ]
        )
    }
}

extension ReynardDefaultPreferencesViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        searchChanged()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
