import FilaBackendKit
@testable import FilaClient
import Foundation
import Testing

@Suite("Allowlisted configuration backup")
@MainActor
struct ConfigurationBackupTests {
    private let containerKey = "wiki.qaq.fila.local.container"

    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
        let name = "wiki.qaq.fila.tests.configuration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, name)
    }

    private func envelope(mode: String = "fullRoot", general: [String: Any] = [:], local: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "magic": "wiki.qaq.fila.configuration", "version": 1,
            "mode": mode, "general": general, "local": local,
        ], options: [.sortedKeys])
    }

    @Test
    func fullRootRoundTripPreservesAliasesAndOrder() throws {
        try withDefaults { defaults, domain in
            defaults.set(["/etc", "/var/mobile"], forKey: "favorites")
            defaults.set(["/etc": "System", "/var/mobile": "Home"], forKey: "favoriteNames")
            defaults.set([7, 3, 0], forKey: "presetOrder")
            defaults.set([4, 5], forKey: "hiddenPresets")
            defaults.set(["/etc": "grid"], forKey: "folderLayouts")
            defaults.set("kind", forKey: "sortKey")
            defaults.set(false, forKey: "sortAscending")
            defaults.set(true, forKey: "showsHidden")
            defaults.set("list", forKey: "layout")
            defaults.set("/var/jb", forKey: "favoritesInstallRoot")
            defaults.set("home", forKey: "launchLocation")
            defaults.set(false, forKey: "usesTrash")
            defaults.set(false, forKey: "wrapsLines")
            defaults.set(false, forKey: "highlightsSyntax")
            defaults.set(false, forKey: "redirectsScriptInterpreters")
            defaults.set(false, forKey: "recordsRecents")
            let data = try ConfigurationBackupNamespace.capture(defaults: defaults, mode: .fullRoot)
            defaults.set(["/"], forKey: "favorites")
            defaults.set("size", forKey: "sortKey")
            try ConfigurationBackupNamespace.decode(data).restore(defaults: defaults, domainName: domain, mode: .fullRoot)
            #expect(try ConfigurationBackupNamespace.capture(defaults: defaults, mode: .fullRoot) == data)
            #expect(defaults.stringArray(forKey: "favorites") == ["/etc", "/var/mobile"])
            #expect(defaults.dictionary(forKey: "favoriteNames") as? [String: String] == ["/etc": "System", "/var/mobile": "Home"])
            #expect(defaults.array(forKey: "presetOrder") as? [Int] == [7, 3, 0])
            #expect(ConfigurationBackupNamespace.fileExtension == "filaconfig")
            #expect(ConfigurationBackupNamespace.maximumFileSize <= 1_048_576)
        }
    }

    @Test
    func captureExcludesSecretsServersHistoryTabsAndForeignKeys() throws {
        try withDefaults { defaults, _ in
            for key in ["serverPassword", "serverUsername", "serverPort", "serverRoot", "serverBackground",
                        "token", "password", "servers", "tabs", "lastDirectory", "recents", "recentVisits", "recentFiles"] {
                defaults.set("sensitive-marker", forKey: key)
            }
            defaults.set(Data("sensitive-marker".utf8), forKey: containerKey)
            let data = try ConfigurationBackupNamespace.capture(defaults: defaults, mode: .fullRoot)
            #expect(!String(decoding: data, as: UTF8.self).contains("sensitive-marker"))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((object["general"] as? [String: Any])?.isEmpty == true)
            #expect((object["local"] as? [String: Any])?.isEmpty == true)
        }
    }

    @Test
    func missingManagedKeysResetAndForeignKeysStayUnchanged() throws {
        try withDefaults { defaults, domain in
            defaults.set(false, forKey: "usesTrash")
            defaults.set("size", forKey: "sortKey")
            defaults.set(["/etc"], forKey: "favorites")
            defaults.set("keep", forKey: "serverPassword")
            defaults.set(["/history"], forKey: "recents")
            defaults.set("/last", forKey: "lastDirectory")
            defaults.set(Data([1, 2, 3]), forKey: containerKey)
            let backup = try ConfigurationBackupNamespace.decode(envelope(local: ["favorites": []]))
            try backup.restore(defaults: defaults, domainName: domain, mode: .fullRoot)
            #expect(defaults.stringArray(forKey: "favorites") == [])
            #expect(defaults.object(forKey: "usesTrash") == nil)
            #expect(defaults.object(forKey: "sortKey") == nil)
            #expect(defaults.string(forKey: "serverPassword") == "keep")
            #expect(defaults.stringArray(forKey: "recents") == ["/history"])
            #expect(defaults.string(forKey: "lastDirectory") == "/last")
            #expect(defaults.data(forKey: containerKey) == Data([1, 2, 3]))
        }
    }

    @Test
    func invalidInputsAreRejectedBeforeAnyWrites() throws {
        try withDefaults { defaults, domain in
            defaults.set("keep", forKey: "foreign")
            defaults.set(false, forKey: "usesTrash")
            let before = defaults.persistentDomain(forName: domain)! as NSDictionary
            let invalid: [[String: Any]] = [
                ["sortKey": "execute"], ["layout": "script"], ["sortAscending": 1],
                ["showsHidden": "true"], ["favorites": "/etc"], ["favorites": ["/../etc"]],
                ["favorites": ["/etc//passwd"]], ["favorites": ["relative"]],
                ["favorites": ["/etc/"]], ["favorites": ["/nul\0x"]],
                ["favorites": ["/etc", "/etc"]], ["favorites": ["file:///etc"]],
                ["favorites": ["/etc"], "favoriteNames": ["/other": "Other"]],
                ["presetOrder": [99]], ["presetOrder": [true]], ["presetOrder": [1, 1]],
                ["folderLayouts": ["/etc": "unknown"]], ["serverPassword": "no"],
                ["recents": []], ["lastDirectory": "/etc"], ["sortKey": NSNull()],
            ]
            for local in invalid {
                #expect(throws: (any Error).self) {
                    try ConfigurationBackupNamespace.decode(envelope(local: local))
                        .restore(defaults: defaults, domainName: domain, mode: .fullRoot)
                }
                #expect((defaults.persistentDomain(forName: domain)! as NSDictionary) == before)
            }
            for general in [["usesTrash": 1], ["launchLocation": "unknown"], ["serverPort": 8080]] as [[String: Any]] {
                #expect(throws: (any Error).self) { try ConfigurationBackupNamespace.decode(envelope(general: general)) }
            }
        }
    }

    @Test
    func envelopeAndBudgetsAreStrict() throws {
        let valid = try envelope()
        for (key, value) in [("magic", "wrong" as Any), ("version", 2 as Any),
                             ("mode", "remote" as Any), ("executable", "payload" as Any)] {
            var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            object[key] = value
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try ConfigurationBackupNamespace.decode(data) }
        }
        #expect(throws: (any Error).self) {
            try ConfigurationBackupNamespace.decode(Data(repeating: 32, count: ConfigurationBackupNamespace.maximumFileSize + 1))
        }
        #expect(throws: (any Error).self) {
            try ConfigurationBackupNamespace.decode(envelope(local: ["favorites": (0 ... 512).map { "/f\($0)" }]))
        }
        #expect(throws: (any Error).self) {
            try ConfigurationBackupNamespace.decode(envelope(local: ["folderLayouts": Dictionary(uniqueKeysWithValues: (0 ... 200).map { ("/f\($0)", "grid") })]))
        }
        #expect(throws: (any Error).self) {
            try ConfigurationBackupNamespace.decode(envelope(local: ["favorites": ["/etc"], "favoriteNames": ["/etc": String(repeating: "a", count: 257)]]))
        }
        #expect(throws: (any Error).self) {
            try ConfigurationBackupNamespace.decode(envelope(local: ["favorites": ["/" + String(repeating: "a", count: 256)]]))
        }
    }

    @Test
    func publicAPIRoundTripsIndependentNamespacesWithoutExportingHistory() throws {
        try withDefaults { defaults, domain in
            defaults.set(["/etc", "/var/mobile"], forKey: "favorites")
            defaults.set(["/etc": "System"], forKey: "favoriteNames")
            defaults.set("/etc", forKey: "launchLocation")
            var original = try LocalFilePreferences(
                files: FileBackendPreferences(
                    favorites: [ServicePath("Documents"), ServicePath.root],
                    favoriteNames: ["Documents": "My documents", "": "Container"],
                    recents: [.init(path: ServicePath("source-history-marker"), visited: nil)],
                    lastDirectory: ServicePath("source-last-marker"),
                    sortKey: .size, sortAscending: false, showsHidden: true,
                    layout: .grid, folderLayouts: [ServicePath("Documents"): .list]
                ), presetOrder: [.inbox, .root], hiddenPresets: [.music]
            )
            try UserDefaultsStorage<LocalFilePreferences>(defaults: defaults, key: containerKey).save(original)
            let data = try ConfigurationBackup.capture(defaults: defaults)
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("source-history-marker"))
            #expect(!text.contains("source-last-marker"))
            #expect(!text.contains("recents"))
            #expect(!text.contains("lastDirectory"))
            #expect(ConfigurationBackup.fileExtension == "filaconfig")
            #expect(ConfigurationBackup.maximumFileSize == 1_048_576)

            original.files.recents = [try .init(path: ServicePath("target-history"), visited: Date(timeIntervalSince1970: 100))]
            original.files.lastDirectory = try ServicePath("target-last")
            var current = original
            current.files.favorites = []
            current.files.favoriteNames = nil
            current.files.layout = .list
            current.files.folderLayouts = [:]
            try UserDefaultsStorage<LocalFilePreferences>(defaults: defaults, key: containerKey).save(current)
            var record = try #require(JSONSerialization.jsonObject(with: defaults.data(forKey: containerKey)!) as? [String: Any])
            record["futureForeignField"] = "keep"
            defaults.set(try JSONSerialization.data(withJSONObject: record), forKey: containerKey)
            defaults.set(["/other"], forKey: "favorites")
            try ConfigurationBackup.decode(data).restore(defaults: defaults, domainName: domain)
            let restored = try UserDefaultsStorage<LocalFilePreferences>(defaults: defaults, key: containerKey).load()
            #expect(restored == original)
            #expect(defaults.stringArray(forKey: "favorites") == ["/etc", "/var/mobile"])
            let saved = try #require(JSONSerialization.jsonObject(with: defaults.data(forKey: containerKey)!) as? [String: Any])
            #expect(saved["futureForeignField"] as? String == "keep")
            #expect(try ConfigurationBackup.capture(defaults: defaults) == data)
        }
    }

    @Test
    func namespacesCannotBeSwappedOrReinterpreted() throws {
        try withDefaults { defaults, domain in
            let data = try ConfigurationBackup.capture(defaults: defaults)
            var record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let root = record["fullRoot"]
            record["fullRoot"] = record["container"]
            record["container"] = root
            #expect(throws: (any Error).self) {
                try ConfigurationBackup.decode(JSONSerialization.data(withJSONObject: record))
                    .restore(defaults: defaults, domainName: domain)
            }
            #expect(throws: (any Error).self) {
                try ConfigurationBackupNamespace.decode(envelope(mode: "container", local: ["favorites": ["/etc"]]))
            }
            #expect(throws: (any Error).self) {
                try ConfigurationBackupNamespace.decode(envelope(local: ["favorites": ["Documents"]]))
            }
            #expect(defaults.object(forKey: "favorites") == nil)
            #expect(defaults.object(forKey: containerKey) == nil)
        }
    }

    @Test
    func invalidDestinationContainerIsDetectedBeforeGeneralOrFullRootWrites() throws {
        try withDefaults { defaults, domain in
            let backup = try ConfigurationBackup.decode(ConfigurationBackup.capture(defaults: defaults))
            defaults.set(false, forKey: "usesTrash")
            defaults.set(["/etc"], forKey: "favorites")
            defaults.set(Data("corrupt".utf8), forKey: containerKey)
            let before = defaults.persistentDomain(forName: domain)! as NSDictionary
            #expect(throws: (any Error).self) { try backup.restore(defaults: defaults, domainName: domain) }
            #expect((defaults.persistentDomain(forName: domain)! as NSDictionary) == before)
        }
    }

    @Test
    func publicEnvelopeRejectsUnknownKeysFutureVersionsAndOversize() throws {
        try withDefaults { defaults, _ in
            let data = try ConfigurationBackup.capture(defaults: defaults)
            for (key, value) in [("version", 2 as Any), ("script", "exec" as Any), ("magic", "wrong" as Any)] {
                var record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                record[key] = value
                #expect(throws: (any Error).self) {
                    try ConfigurationBackup.decode(JSONSerialization.data(withJSONObject: record))
                }
            }
            #expect(throws: (any Error).self) {
                try ConfigurationBackup.decode(Data(repeating: 32, count: ConfigurationBackup.maximumFileSize + 1))
            }
        }
    }

    @Test
    func absentContainerFieldsResetWithoutRemovingCurrentHistory() throws {
        try withDefaults { defaults, domain in
            let backup = try ConfigurationBackup.decode(ConfigurationBackup.capture(defaults: defaults))
            let current = try LocalFilePreferences(
                files: FileBackendPreferences(
                    favorites: [ServicePath("Documents")], favoriteNames: ["Documents": "Mine"],
                    recents: [.init(path: ServicePath("keep-history"), visited: nil)],
                    lastDirectory: ServicePath("keep-last"), sortKey: .size, sortAscending: false,
                    showsHidden: true, layout: .grid, folderLayouts: [ServicePath.root: .grid]
                ), presetOrder: [.trash], hiddenPresets: [.root]
            )
            try UserDefaultsStorage<LocalFilePreferences>(defaults: defaults, key: containerKey).save(current)
            try backup.restore(defaults: defaults, domainName: domain)
            let restored = try #require(try UserDefaultsStorage<LocalFilePreferences>(defaults: defaults, key: containerKey).load())
            var expected = LocalFilePreferences()
            expected.files.recents = current.files.recents
            expected.files.lastDirectory = current.files.lastDirectory
            #expect(restored == expected)
        }
    }

    @Test
    func rootfulEmptyInstallPrefixRoundTrips() throws {
        try withDefaults { defaults, domain in
            defaults.set("", forKey: "favoritesInstallRoot")
            let data = try ConfigurationBackup.capture(defaults: defaults)
            defaults.set("/different", forKey: "favoritesInstallRoot")
            try ConfigurationBackup.decode(data).restore(defaults: defaults, domainName: domain)
            #expect(defaults.string(forKey: "favoritesInstallRoot") == "")
        }
    }

    @Test
    func persistenceFailureRollsBackManagedKeysOnly() throws {
        let domain = "wiki.qaq.fila.tests.configuration.rollback.\(UUID().uuidString)"
        let defaults = ConfigurationBackupFailingDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let backup = try ConfigurationBackup.decode(ConfigurationBackup.capture(defaults: defaults))
        defaults.set(false, forKey: "usesTrash")
        defaults.set(["/etc"], forKey: "favorites")
        defaults.set("keep", forKey: "foreign")
        #expect(defaults.synchronize())
        defaults.failuresRemaining = 1
        #expect(throws: (any Error).self) { try backup.restore(defaults: defaults, domainName: domain) }
        #expect(defaults.object(forKey: "usesTrash") as? Bool == false)
        #expect(defaults.stringArray(forKey: "favorites") == ["/etc"])
        #expect(defaults.string(forKey: "foreign") == "keep")
        #expect(defaults.object(forKey: containerKey) == nil)
    }
}

private final class ConfigurationBackupFailingDefaults: UserDefaults {
    var failuresRemaining = 0

    override func synchronize() -> Bool {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            return false
        }
        return super.synchronize()
    }
}
