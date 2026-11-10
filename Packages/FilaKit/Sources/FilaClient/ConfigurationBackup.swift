import CoreFoundation
import FilaBackendKit
import Foundation

public enum ConfigurationBackupFailure: Error, Sendable {
    case invalidFormat, unsupportedVersion, tooLarge, wrongStorageMode
    case persistenceFailed, rollbackFailed, invalidDomain
}

/// A data-only, allowlisted snapshot. It never contains server settings or visit history.
/// Apply before constructing preference-owning backends; existing caches must not save over it.
struct ConfigurationBackupNamespace: Codable, Sendable {
    public static let fileExtension = "filaconfig"
    public static let maximumFileSize = 1_048_576

    public enum StorageMode: String, Codable, Sendable {
        case fullRoot
        case container
    }

    typealias Failure = ConfigurationBackupFailure

    public let mode: StorageMode
    private let magic: String
    private let version: Int
    private let general: General
    private let local: Local

    private static let signature = "wiki.qaq.fila.configuration"
    private static let containerKey = "wiki.qaq.fila.local.container"
    private static let generalKeys: Set<String> = [
        "launchLocation", "usesTrash", "wrapsLines", "highlightsSyntax",
        "redirectsScriptInterpreters", "recordsRecents",
    ]
    private static let localKeys: Set<String> = [
        "favorites", "favoriteNames", "favoritesInstallRoot", "sortKey",
        "sortAscending", "showsHidden", "layout", "folderLayouts", "presetOrder", "hiddenPresets",
    ]
    private static let fileKeys: Set<String> = [
        "favorites", "favoriteNames", "sortKey", "sortAscending", "showsHidden", "layout", "folderLayouts",
    ]

    private struct General: Codable, Sendable {
        var launchLocation: String?
        var usesTrash: Bool?
        var wrapsLines: Bool?
        var highlightsSyntax: Bool?
        var redirectsScriptInterpreters: Bool?
        var recordsRecents: Bool?
    }

    /// Paths use the source storage's spelling: absolute for fullRoot, relative for container.
    private struct Local: Codable, Sendable {
        var favorites: [String]?
        var favoriteNames: [String: String]?
        var favoritesInstallRoot: String?
        var sortKey: FileSortKey?
        var sortAscending: Bool?
        var showsHidden: Bool?
        var layout: BrowserLayout?
        var folderLayouts: [String: BrowserLayout]?
        var presetOrder: [LocalPreset]?
        var hiddenPresets: [LocalPreset]?
    }

    @MainActor
    public static func capture(defaults: UserDefaults = .standard, mode: StorageMode) throws -> Data {
        var general: [String: Any] = [:]
        for key in generalKeys { general[key] = defaults.object(forKey: key) }
        var local: [String: Any] = [:]
        switch mode {
        case .fullRoot:
            for key in localKeys { local[key] = defaults.object(forKey: key) }
        case .container:
            if let raw = defaults.object(forKey: containerKey) {
                guard let data = raw as? Data else { throw Failure.invalidFormat }
                let record = try object(data)
                let preferences = try JSONDecoder().decode(LocalFilePreferences.self, from: data)
                guard let files = record["files"] as? [String: Any] else { throw Failure.invalidFormat }
                for key in fileKeys { local[key] = files[key] }
                // A dictionary with ServicePath keys uses Codable's alternating-array form.
                local["folderLayouts"] = Dictionary(uniqueKeysWithValues: preferences.files.folderLayouts.map {
                    ($0.key.description, $0.value.rawValue)
                })
                for key in ["presetOrder", "hiddenPresets", "favoritesInstallRoot"] { local[key] = record[key] }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "magic": signature, "version": 1, "mode": mode.rawValue,
            "general": general, "local": local,
        ], options: [.sortedKeys])
        // The same strict trust boundary applies to locally stored, possibly old values.
        _ = try decode(data)
        return data
    }

    public static func decode(_ data: Data) throws -> ConfigurationBackupNamespace {
        guard data.count <= maximumFileSize else { throw Failure.tooLarge }
        let root = try object(data)
        try keys(root, allowed: ["magic", "version", "mode", "general", "local"])
        guard let general = root["general"] as? [String: Any],
              let local = root["local"] as? [String: Any] else { throw Failure.invalidFormat }
        try keys(general, allowed: generalKeys)
        try keys(local, allowed: localKeys)
        // JSON booleans and numbers must not be interchangeable through NSNumber bridging.
        for dictionary in [general, local] {
            for key in ["usesTrash", "wrapsLines", "highlightsSyntax", "redirectsScriptInterpreters",
                        "recordsRecents", "sortAscending", "showsHidden"] {
                if let value = dictionary[key] {
                    guard let number = value as? NSNumber,
                          CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure.invalidFormat }
                }
            }
            guard !dictionary.values.contains(where: { $0 is NSNull }) else { throw Failure.invalidFormat }
        }
        guard let version = root["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1 else {
            throw Failure.unsupportedVersion
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    @MainActor
    public func restore(defaults: UserDefaults, domainName: String, mode: StorageMode) throws {
        let prepared = try updates(defaults: defaults, mode: mode)
        try Self.apply(prepared.values, managed: prepared.managed, defaults: defaults, domainName: domainName)
    }

    @MainActor
    func updates(defaults: UserDefaults, mode: StorageMode) throws -> (values: [String: Any], managed: Set<String>) {
        try validate()
        guard self.mode == mode else { throw Failure.wrongStorageMode }
        let encoded = try JSONEncoder().encode(self)
        _ = try Self.decode(encoded)
        let root = try Self.object(encoded)
        let general = root["general"] as! [String: Any]
        let local = root["local"] as! [String: Any]
        var updates = general
        var managed = Self.generalKeys
        switch mode {
        case .fullRoot:
            managed.formUnion(Self.localKeys)
            updates.merge(local) { _, new in new }
        case .container:
            managed.insert(Self.containerKey)
            // Merge only managed fields into the current record, preserving history,
            // lastDirectory and fields belonging to a newer app version.
            var record: [String: Any]
            if let raw = defaults.object(forKey: Self.containerKey) {
                guard let data = raw as? Data else { throw Failure.invalidFormat }
                record = try Self.object(data)
                _ = try JSONDecoder().decode(LocalFilePreferences.self, from: data)
            } else {
                record = try Self.object(JSONEncoder().encode(LocalFilePreferences()))
            }
            var files = record["files"] as? [String: Any] ?? [:]
            let baseline = try Self.object(JSONEncoder().encode(LocalFilePreferences()))
            let defaultFiles = baseline["files"] as! [String: Any]
            for key in Self.fileKeys { files[key] = local[key] ?? defaultFiles[key] }
            if let layouts = self.local.folderLayouts {
                let native = try Dictionary(uniqueKeysWithValues: layouts.map { (try ServicePath($0.key), $0.value) })
                files["folderLayouts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(native))
            }
            record["files"] = files
            for key in ["presetOrder", "hiddenPresets", "favoritesInstallRoot"] {
                record[key] = local[key] ?? baseline[key]
            }
            updates[Self.containerKey] = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        }
        return (updates, managed)
    }

    @MainActor
    static func apply(_ updates: [String: Any], managed: Set<String>, defaults: UserDefaults, domainName: String) throws {
        guard !domainName.isEmpty else { throw Failure.invalidDomain }
        // Never replace a whole defaults domain: foreign keys are outside this transaction.
        let oldDomain = defaults.persistentDomain(forName: domainName) ?? [:]
        for key in managed {
            if let value = updates[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        guard defaults.synchronize() else {
            for key in managed {
                if let value = oldDomain[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            guard defaults.synchronize() else { throw Failure.rollbackFailed }
            throw Failure.persistenceFailed
        }
    }

    private func validate() throws {
        guard magic == Self.signature else { throw Failure.invalidFormat }
        guard version == 1 else { throw Failure.unsupportedVersion }
        var stringBytes = 0
        func string(_ value: String, limit: Int) throws {
            guard value.utf8.count <= limit,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw Failure.invalidFormat
            }
            stringBytes += value.utf8.count
            guard stringBytes <= 262_144 else { throw Failure.tooLarge }
        }
        func path(_ value: String, absolute: Bool) throws {
            try string(value, limit: 4096)
            guard value.hasPrefix("/") == absolute else { throw Failure.invalidFormat }
            let parsed = try ServicePath(value)
            guard value == (absolute ? "/" : "") + parsed.description,
                  parsed.components.allSatisfy({ $0.utf8.count <= 255 }) else { throw Failure.invalidFormat }
        }
        if let launch = general.launchLocation {
            try string(launch, limit: 4096)
            if !["root", "home", "lastVisited"].contains(launch) {
                // This app preference is absolute even when the container backend ignores it.
                try path(launch, absolute: true)
            }
        }
        let favorites = local.favorites ?? []
        guard favorites.count <= 512, Set(favorites).count == favorites.count,
              (local.favoriteNames?.count ?? 0) <= 512,
              (local.folderLayouts?.count ?? 0) <= FileBackendPreferences.folderLayoutLimit else {
            throw Failure.invalidFormat
        }
        let absolute = mode == .fullRoot
        for favorite in favorites { try path(favorite, absolute: absolute) }
        for (favorite, alias) in local.favoriteNames ?? [:] {
            try path(favorite, absolute: absolute)
            guard favorites.contains(favorite), !alias.isEmpty else { throw Failure.invalidFormat }
            try string(alias, limit: 256)
        }
        for folder in (local.folderLayouts ?? [:]).keys { try path(folder, absolute: absolute) }
        if let installRoot = local.favoritesInstallRoot {
            guard mode == .fullRoot else { throw Failure.invalidFormat }
            // A rootful backend deliberately has no install prefix.
            if !installRoot.isEmpty { try path(installRoot, absolute: true) }
        }
        for presets in [local.presetOrder, local.hiddenPresets] {
            if let presets {
                guard presets.count <= LocalPreset.allCases.count,
                      Set(presets).count == presets.count else { throw Failure.invalidFormat }
            }
        }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumFileSize else { throw Failure.tooLarge }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidFormat
        }
        return object
    }

    private static func keys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw Failure.invalidFormat }
    }
}

/// Portable settings and both local namespaces, never a dump of UserDefaults.
/// Restore before any preference-owning singleton is initialized. domainName must
/// identify the supplied defaults' persistent domain (bundle ID or isolated suite name).
public struct ConfigurationBackup: Codable, Sendable {
    public static let fileExtension = "filaconfig"
    public static let maximumFileSize = 1_048_576

    private let magic: String
    private let version: Int
    private let fullRoot: ConfigurationBackupNamespace
    private let container: ConfigurationBackupNamespace

    @MainActor
    public static func capture(defaults: UserDefaults = .standard) throws -> Data {
        let rootData = try ConfigurationBackupNamespace.capture(defaults: defaults, mode: .fullRoot)
        let containerData = try ConfigurationBackupNamespace.capture(defaults: defaults, mode: .container)
        let value = try ConfigurationBackup(
            magic: "wiki.qaq.fila.configuration-backup", version: 1,
            fullRoot: ConfigurationBackupNamespace.decode(rootData),
            container: ConfigurationBackupNamespace.decode(containerData)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        _ = try decode(data)
        return data
    }

    public static func decode(_ data: Data) throws -> ConfigurationBackup {
        typealias Failure = ConfigurationBackupNamespace.Failure
        guard data.count <= maximumFileSize else { throw Failure.tooLarge }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["magic", "version", "fullRoot", "container"],
              root["magic"] as? String == "wiki.qaq.fila.configuration-backup" else { throw Failure.invalidFormat }
        guard let version = root["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1 else {
            throw Failure.unsupportedVersion
        }
        guard let rootRecord = root["fullRoot"] as? [String: Any],
              let containerRecord = root["container"] as? [String: Any] else { throw Failure.invalidFormat }
        let fullRoot = try ConfigurationBackupNamespace.decode(JSONSerialization.data(withJSONObject: rootRecord))
        let container = try ConfigurationBackupNamespace.decode(JSONSerialization.data(withJSONObject: containerRecord))
        guard fullRoot.mode == .fullRoot, container.mode == .container else { throw Failure.wrongStorageMode }
        let rootGeneral = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fullRoot)) as! [String: Any]
        let containerGeneral = try JSONSerialization.jsonObject(with: JSONEncoder().encode(container)) as! [String: Any]
        guard (rootGeneral["general"] as! NSDictionary) == (containerGeneral["general"] as! NSDictionary) else {
            throw Failure.invalidFormat
        }
        return ConfigurationBackup(magic: "wiki.qaq.fila.configuration-backup", version: 1, fullRoot: fullRoot, container: container)
    }

    @MainActor
    public func restore(defaults: UserDefaults, domainName: String) throws {
        let validated = try Self.decode(JSONEncoder().encode(self))
        let root = try validated.fullRoot.updates(defaults: defaults, mode: .fullRoot)
        let container = try validated.container.updates(defaults: defaults, mode: .container)
        // Both records, including the destination's preserved container history, are
        // fully prepared before the first defaults write.
        let updates = root.values.merging(container.values) { _, new in new }
        try ConfigurationBackupNamespace.apply(
            updates, managed: root.managed.union(container.managed), defaults: defaults, domainName: domainName
        )
    }
}
