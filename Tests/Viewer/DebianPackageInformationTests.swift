import Foundation
import Testing

struct DebianPackageInformationTests {
    private let control = """
    Package: com.example.one
    Version: 1.0
    Architecture: iphoneos-arm64e
    Description: Summary
     Long description stays here.
    Depends: firmware (>= 15.0)
    Maintainer: Someone
    X-Unknown: keep me

    """

    @Test
    func missingInformationCanBeFilledWithoutGuessingAnIdentity() throws {
        var info = try DebianPackageInformation(control: "Depends: firmware\n", architecture: "iphoneos-arm64e")
        #expect(!info.hasPackageIdentifier)
        #expect(info.package.isEmpty && info.version.isEmpty && info.descriptionText.isEmpty)
        #expect(throws: DebianControlFailure.self) { try info.controlText() }
        info.package = "com.example.two"
        info.version = "0.8.4-1"
        info.descriptionText = "A plugin"
        let fields = try ControlFields(text: info.controlText())
        #expect(fields.value(of: "Package") == "com.example.two")
        #expect(fields.value(of: "Version") == "0.8.4-1")
        #expect(fields.value(of: "Depends") == "firmware")
        #expect(fields.value(of: "X-WM0104-Changelog") == nil)
    }

    @Test
    func fieldsAndLongDescriptionSurviveAndRepeatedPackingDoesNotAppendLogs() throws {
        var info = try DebianPackageInformation(control: control, architecture: "iphoneos-arm64e")
        info.descriptionText = "New summary\nLong description stays here."
        info.version = "1.1-2"
        info.date = "2026-11-11"
        info.changes = "One very long update that remains one entry even when its input view wraps it.\nSecond update"
        info.icon = "https://example.com/images/one.png"
        let text = try info.controlText()
        let fields = try ControlFields(text: text)
        #expect(fields.value(of: "Description") == "New summary")
        #expect(text.contains("\n Long description stays here.\n"))
        #expect(fields.value(of: "Depends") == "firmware (>= 15.0)")
        #expect(fields.value(of: "Maintainer") == "Someone")
        #expect(fields.value(of: "X-Unknown") == "keep me")
        #expect(fields.value(of: "Icon") == info.icon)
        let log = try #require(fields.value(of: "X-WM0104-Changelog"))
        #expect(log.components(separatedBy: "；").count == 2)
        #expect(log.hasPrefix("1.1-2 | 2026-11-11 | "))
        let reopened = try DebianPackageInformation(control: text, architecture: "iphoneos-arm64e")
        #expect(reopened.changes == info.changes)
        #expect(try reopened.controlText() == text)
    }

    @Test
    func blankUpdatesEraseAnOldLogEvenAfterAVersionChange() throws {
        var info = try DebianPackageInformation(control: control + "X-WM0104-Changelog: 1.0 | 2026-11-10 | Old update\n", architecture: "iphoneos-arm64e")
        #expect(info.changes == "Old update")
        #expect(info.date == "2026-11-10")
        info.changes = ""
        #expect(try ControlFields(text: info.controlText()).value(of: "X-WM0104-Changelog") == nil)
        info.version = "1.1"
        let text = try info.controlText()
        let reopened = try DebianPackageInformation(control: text, architecture: "iphoneos-arm64e")
        #expect(reopened.changes.isEmpty)
        #expect(reopened.date == "2026-11-10")
        #expect(try reopened.controlText() == text)
    }

    @Test
    func independentDateWinsAndSavesWithoutUpdateText() throws {
        let input = control + "X-WM0104-Changelog: 1.0 | 2026-11-10 | Old update\nX-WM0104-Release-Date: 2026-11-11\n"
        var info = try DebianPackageInformation(control: input, architecture: "iphoneos-arm64e")
        #expect(info.date == "2026-11-11")
        #expect(info.changes == "Old update")
        info.date = "2024-02-29"
        info.changes = ""
        let text = try info.controlText()
        let fields = try ControlFields(text: text)
        #expect(fields.value(of: "X-WM0104-Release-Date") == "2024-02-29")
        #expect(fields.value(of: "X-WM0104-Changelog") == nil)
        let reopened = try DebianPackageInformation(control: text, architecture: "iphoneos-arm64e")
        #expect(reopened.date == info.date)
        #expect(reopened.changes.isEmpty)
        info.date = "2026-02-30"
        #expect(throws: DebianControlFailure.self) { try info.controlText() }
    }

    @Test
    func legacyRepoPocketUpdatesLoadMigrateAndClearWithoutComingBack() throws {
        let base = control.replacingOccurrences(of: "com.example.one", with: "com.wm0104.repopocket")
        let legacy = "X-RepoPocket-Changelog: 1.0 | 2026-11-09 | Legacy update\n"
        var info = try DebianPackageInformation(control: base + legacy, architecture: "iphoneos-arm64e")
        #expect(info.changes == "Legacy update")
        #expect(info.date == "2026-11-09")
        let migrated = try ControlFields(text: info.controlText())
        #expect(migrated.value(of: "X-RepoPocket-Changelog") == nil)
        #expect(migrated.value(of: "X-WM0104-Changelog") == "1.0 | 2026-11-09 | Legacy update")
        info.changes = ""
        info.version = "1.1"
        let cleared = try ControlFields(text: info.controlText())
        #expect(cleared.value(of: "X-RepoPocket-Changelog") == nil)
        #expect(cleared.value(of: "X-WM0104-Changelog") == nil)
        #expect(cleared.value(of: "X-WM0104-Release-Date") == "2026-11-09")
        let unified = "X-WM0104-Changelog: 1.0 | 2026-11-10 | Unified update\n"
        info = try DebianPackageInformation(control: base + legacy + unified, architecture: "iphoneos-arm64e")
        #expect(info.changes == "Unified update")
        info.changes = ""
        let bothCleared = try ControlFields(text: info.controlText())
        #expect(bothCleared.value(of: "X-RepoPocket-Changelog") == nil)
        #expect(bothCleared.value(of: "X-WM0104-Changelog") == nil)
        let unrelated = try DebianPackageInformation(control: control + legacy, architecture: "iphoneos-arm64e")
        #expect(unrelated.changes.isEmpty)
        #expect(try ControlFields(text: unrelated.controlText()).value(of: "X-RepoPocket-Changelog") == "1.0 | 2026-11-09 | Legacy update")
    }

    @Test
    func defaultDateUsesTheCurrentTimeZone() throws {
        let now = Date(timeIntervalSince1970: 1794412800)
        let info = try DebianPackageInformation(control: control, architecture: "iphoneos-arm64e", now: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        #expect(info.date == formatter.string(from: now))
    }

    @Test
    func completeDescriptionLoadsAndUnchangedControlKeepsItsEncoding() throws {
        let input = control.replacingOccurrences(
            of: " Long description stays here.\n",
            with: " Long description stays here.\n .\n\t第二段 العربية 🌍\n  indented\n",
        )
        let info = try DebianPackageInformation(control: input, architecture: "iphoneos-arm64e")
        #expect(info.descriptionText == "Summary\nLong description stays here.\n\n第二段 العربية 🌍\n indented")
        #expect(try info.controlText() == input + "X-WM0104-Release-Date: \(info.date)\n")
    }

    @Test(arguments: ["仅保留摘要", "Updated\nReplacement\n\n日本語 العربية 🌍\n last line\n", "Tabs\n\tindented\n. text"])
    func editedDescriptionReplacesAllOldContinuationLines(_ edited: String) throws {
        var info = try DebianPackageInformation(control: control, architecture: "iphoneos-arm64e")
        info.descriptionText = edited
        let text = try info.controlText()
        let reopened = try DebianPackageInformation(control: text, architecture: "iphoneos-arm64e")
        #expect(reopened.descriptionText == edited)
        #expect(!text.contains("Long description stays here."))
        #expect(text.contains("Depends: firmware (>= 15.0)\nMaintainer: Someone\nX-Unknown: keep me\n"))
        #expect(try reopened.controlText() == text)
    }

    @Test
    func descriptionCannotInjectFieldsOrChangeOtherFieldSetSemantics() throws {
        var info = try DebianPackageInformation(control: control, architecture: "iphoneos-arm64e")
        info.descriptionText = "Safe\nPackage: injected\nDepends: injected"
        let fields = try ControlFields(text: info.controlText())
        #expect(fields.value(of: "Package") == "com.example.one")
        #expect(fields.value(of: "Depends") == "firmware (>= 15.0)")
        var other = try ControlFields(text: "Package: one\nX-Other: first\n continuation\n")
        other.set("X-Other", "changed")
        #expect(other.text == "Package: one\nX-Other: changed\n continuation\n")
    }

    @Test(arguments: ["Safe\n.\nBody", "Safe\n   \nBody", "Safe\n\t\t\nBody"])
    func unrepresentableDescriptionLinesAreExplicitlyRefused(_ edited: String) throws {
        var info = try DebianPackageInformation(control: control, architecture: "iphoneos-arm64e")
        info.descriptionText = edited
        #expect(throws: DebianControlFailure.self) { try info.controlText() }
        var fields = try ControlFields(text: control)
        #expect(throws: DebianControlFailure.self) { try fields.setDescription(edited) }
        #expect(fields.text == control)
    }

    @Test(arguments: ["", "   ", "\nBody", "Safe\nBad\0line", "Safe\nBad\rline", "Safe\nBad\u{7f}line"])
    func invalidOrEmptyDescriptionKeepsTheExistingRequiredBoundary(_ edited: String) throws {
        var info = try DebianPackageInformation(control: control, architecture: "iphoneos-arm64e")
        info.descriptionText = edited
        #expect(throws: DebianControlFailure.self) { try info.controlText() }
    }

    @Test(arguments: ["0.8.4-1", "1:2.0~beta+1-3", "2.0", "1.2.3+build.4"])
    func acceptsDebianVersions(_ version: String) throws {
        var info = try DebianPackageInformation(control: control, architecture: "iphoneos-arm64e")
        info.version = version
        #expect(try ControlFields(text: info.controlText()).value(of: "Version") == version)
    }

    @Test(arguments: ["", "beta", "1.0-", "x:1.0", "1.0\nDepends: injected", "1.0 revision", "1.0_1"])
    func invalidVersionsCannotInjectFields(_ version: String) throws {
        var info = try DebianPackageInformation(control: control, architecture: "iphoneos-arm64e")
        info.version = version
        #expect(throws: DebianControlFailure.self) { try info.controlText() }
    }

    @Test(arguments: ["file:///var/mobile/icon.png", "javascript:alert(1)", "https://user:pass@example.com/a.png", "https://example.com/a.png\nPackage: injected"])
    func iconMustBeAnHTTPImageAddress(_ icon: String) throws {
        var info = try DebianPackageInformation(control: control, architecture: "iphoneos-arm64e")
        info.icon = icon
        #expect(throws: DebianControlFailure.self) { try info.controlText() }
    }

    @Test
    func validatesDateDelimitersAndArchitectureWithoutConvertingPayload() throws {
        var info = try DebianPackageInformation(control: control, architecture: "iphoneos-arm64e")
        info.changes = "Update"
        info.date = "2026-02-30"
        #expect(throws: DebianControlFailure.self) { try info.controlText() }
        info.date = "2024-02-29"
        _ = try info.controlText()
        info.changes = "One；Two"
        #expect(throws: DebianControlFailure.self) { try info.controlText() }
        let mismatch = try DebianPackageInformation(control: control, architecture: "iphoneos-arm64")
        #expect(throws: DebianControlFailure.self) { try mismatch.controlText() }
    }

    @Test(arguments: ["Package: one\npackage: two\n", "Package: one\n\nVersion: 1\n", "Package: one\nVersion: 1\n injected\n", "Package: one\0\n", "Package: one\nX-WM0104-Release-Date: 2026-11-12\n injected\n"])
    func malformedControlsAreRefused(_ text: String) {
        #expect(throws: DebianControlFailure.self) { try ControlFields(text: text) }
    }
}
