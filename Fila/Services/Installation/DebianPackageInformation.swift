import Foundation

struct DebianControlFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Preserves unknown fields and continuation lines in a single binary stanza.
struct ControlFields {
    private(set) var lines: [String]

    init(text: String, requiringPackage: Bool = true) throws {
        guard text.utf8.count <= 1 << 20, !text.utf8.contains(0) else {
            throw DebianControlFailure(message: String(localized: "The control file is invalid or too large."))
        }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        var names = Set<String>()
        var previous = ""
        for line in lines {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard !names.isEmpty, !["package", "version", "architecture", "icon", "x-wm0104-changelog", "x-wm0104-release-date"].contains(previous),
                      !line.utf8.contains(13), !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw DebianControlFailure(message: String(localized: "The control file is invalid or too large."))
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                throw DebianControlFailure(message: String(localized: "The control file is invalid or too large."))
            }
            let name = String(line[..<colon])
            guard !name.isEmpty, !name.hasPrefix("#"), !name.hasPrefix("-"),
                  name.utf8.allSatisfy({ (33...126).contains($0) && $0 != 58 }),
                  !line.utf8.contains(13), names.insert(name.lowercased()).inserted else {
                throw DebianControlFailure(message: String(localized: "The control file contains an invalid or repeated field."))
            }
            previous = name.lowercased()
        }
        if requiringPackage, !names.contains("package") {
            throw DebianControlFailure(message: String(localized: "The control file has no “Package” field."))
        }
        self.lines = lines
    }

    var text: String { lines.joined(separator: "\n") + "\n" }

    private func index(of field: String) -> Int? {
        lines.firstIndex { $0.lowercased().hasPrefix(field.lowercased() + ":") }
    }

    func value(of field: String) -> String? {
        guard let index = index(of: field) else { return nil }
        let value = lines[index].dropFirst(field.count + 1).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Description alone uses Debian's dot line for an empty paragraph.
    var descriptionText: String {
        guard let start = index(of: "Description") else { return "" }
        var result = [value(of: "Description") ?? ""]
        var end = start + 1
        while end < lines.count, lines[end].hasPrefix(" ") || lines[end].hasPrefix("\t") {
            let line = String(lines[end].dropFirst())
            result.append(line == "." ? "" : line)
            end += 1
        }
        return result.joined(separator: "\n")
    }

    mutating func setDescription(_ value: String) throws {
        let parts = value.components(separatedBy: "\n")
        guard parts.dropFirst().allSatisfy({ $0 != "." && ($0.isEmpty || !$0.trimmingCharacters(in: .whitespaces).isEmpty) }) else {
            throw DebianControlFailure(message: String(localized: "A description line cannot contain only whitespace or a single dot. Use an empty line for a paragraph break."))
        }
        // An untouched description keeps its original indentation and spelling.
        guard value != descriptionText else { return }
        let start = index(of: "Description") ?? lines.count
        remove("Description")
        let replacement = ["Description: \(parts[0])"] + parts.dropFirst().map { $0.isEmpty ? " ." : " " + $0 }
        lines.insert(contentsOf: replacement, at: start)
    }

    mutating func set(_ field: String, _ value: String) {
        if let index = index(of: field) { lines[index] = "\(field): \(value)" }
        else { lines.append("\(field): \(value)") }
    }

    mutating func remove(_ field: String) {
        guard let start = index(of: field) else { return }
        var end = start + 1
        while end < lines.count, lines[end].hasPrefix(" ") || lines[end].hasPrefix("\t") { end += 1 }
        lines.removeSubrange(start..<end)
    }
}

struct DebianPackageInformation {
    private let original: ControlFields
    let architecture: String
    let hasPackageIdentifier: Bool
    var package: String
    var version: String
    var descriptionText: String
    var date: String
    var changes: String
    var icon: String

    init(control: String, architecture: String, now: Date = Date()) throws {
        let fields = try ControlFields(text: control, requiringPackage: false)
        original = fields
        self.architecture = architecture
        package = fields.value(of: "Package") ?? ""
        hasPackageIdentifier = !package.isEmpty
        version = fields.value(of: "Version") ?? ""
        descriptionText = fields.descriptionText
        icon = fields.value(of: "Icon") ?? ""
        let formatter = Self.dateFormatter()
        formatter.timeZone = .current
        date = formatter.string(from: now)
        changes = ""
        let changelog = fields.value(of: "X-WM0104-Changelog")
            ?? (package == "com.wm0104.repopocket" ? fields.value(of: "X-RepoPocket-Changelog") : nil)
        if let log = changelog {
            let parts = log.components(separatedBy: " | ")
            if parts.count == 3, parts[0] == version, Self.validDate(parts[1]) {
                date = parts[1]
                changes = parts[2].components(separatedBy: "；").joined(separator: "\n")
            }
        }
        if let savedDate = fields.value(of: "X-WM0104-Release-Date") { date = savedDate }
    }

    func controlText() throws -> String {
        var fields = original
        let package = package.trimmingCharacters(in: .whitespaces)
        let version = version.trimmingCharacters(in: .whitespaces)
        let descriptionLines = descriptionText.components(separatedBy: "\n")
        guard package.range(of: "^[a-z0-9][a-z0-9+.-]+$", options: .regularExpression) != nil else {
            throw DebianControlFailure(message: String(localized: "Enter a valid package identifier, such as com.example.package."))
        }
        guard Self.validVersion(version) else {
            throw DebianControlFailure(message: String(localized: "Enter a valid Debian package version."))
        }
        guard !descriptionLines[0].trimmingCharacters(in: .whitespaces).isEmpty,
              Self.singleLine(descriptionLines[0]),
              descriptionLines.dropFirst().allSatisfy({ line in
                  line.unicodeScalars.allSatisfy { $0.value == 9 || ($0.value >= 32 && $0.value != 127) }
              }) else {
            throw DebianControlFailure(message: String(localized: "Enter a description with a non-empty first line and no control characters."))
        }
        if let declared = original.value(of: "Architecture") {
            let normalized = declared.hasSuffix("arm64e") ? "iphoneos-arm64e"
                : declared.hasSuffix("arm64") ? "iphoneos-arm64" : declared
            guard normalized == architecture else {
                throw DebianControlFailure(message: String(localized: "The selected architecture does not match this package."))
            }
        }
        let icon = icon.trimmingCharacters(in: .whitespaces)
        if !icon.isEmpty {
            guard Self.singleLine(icon), !icon.contains(where: { $0.isWhitespace }),
                  let url = URLComponents(string: icon), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil, url.url != nil else {
                throw DebianControlFailure(message: String(localized: "Enter a public HTTP or HTTPS image link."))
            }
            fields.set("Icon", icon)
        } else { fields.remove("Icon") }

        guard Self.validDate(date) else {
            throw DebianControlFailure(message: String(localized: "Enter the release date as YYYY-MM-DD."))
        }
        // Independent date metadata; the source generator must opt in to this field.
        fields.set("X-WM0104-Release-Date", date)
        let entries = changes.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !entries.isEmpty {
            guard entries.allSatisfy({ Self.singleLine($0) && !$0.contains("；") && !$0.contains(" | ") }) else {
                throw DebianControlFailure(message: String(localized: "Use a new line for each update. Update text cannot contain “；” or “ | ”."))
            }
            fields.set("X-WM0104-Changelog", "\(version) | \(date) | \(entries.joined(separator: "；"))")
        } else { fields.remove("X-WM0104-Changelog") }
        if package == "com.wm0104.repopocket" { fields.remove("X-RepoPocket-Changelog") }
        fields.set("Package", package)
        fields.set("Architecture", architecture)
        fields.set("Version", version)
        try fields.setDescription(descriptionText)
        return try ControlFields(text: fields.text).text
    }

    private static func singleLine(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }

    private static func validVersion(_ value: String) -> Bool {
        // dpkg: optional numeric epoch, digit-led upstream, optional revision.
        var upstream = value[...]
        if let colon = upstream.firstIndex(of: ":") {
            guard !upstream[..<colon].isEmpty, upstream[..<colon].utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
            upstream = upstream[upstream.index(after: colon)...]
        }
        if let dash = upstream.lastIndex(of: "-") {
            let revision = upstream[upstream.index(after: dash)...]
            guard !revision.isEmpty, revision.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43, 46, 126].contains($0) }) else { return false }
            upstream = upstream[..<dash]
        }
        guard let first = upstream.utf8.first, (48...57).contains(first) else { return false }
        return upstream.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43, 45, 46, 58, 126].contains($0) }
    }

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    private static func validDate(_ value: String) -> Bool {
        let formatter = dateFormatter()
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}
