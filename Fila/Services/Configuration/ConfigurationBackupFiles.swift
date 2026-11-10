import Darwin
import FilaClient
import FilaProtocol
import Foundation

/// Only app-owned configuration files; never a destination supplied by a backup.
enum ConfigurationBackupFiles {
    private static let pendingName = "pending.filaconfig"
    private static let preparedName = "prepared.filaconfig"

    @MainActor
    static func export(_ data: Data, into directory: String) async throws -> URL {
        guard data.count <= ConfigurationBackup.maximumFileSize else { throw ConfigurationBackupFailure.tooLarge }
        let session = FileSession.shared
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "Fila-\(stamp)-\(UUID().uuidString.prefix(8)).\(ConfigurationBackup.fileExtension)"
        let parent = URL(fileURLWithPath: directory, isDirectory: true)
        let temporary = parent.appendingPathComponent(".fila-config-\(UUID().uuidString).tmp").path
        let destination = parent.appendingPathComponent(name)
        let file = try await session.perform {
            try await $0.open(temporary, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o600)
        }
        do {
            try await DescriptorIO.blocking { _ in
                defer { close(file) }
                try writeBytes(data, to: file)
            }
            var attributes = AttributeChange.newItemDefaults
            attributes.mode = 0o600 // Favorites and their paths are private configuration.
            _ = try await session.perform { try await $0.setAttributes(attributes, at: temporary) }
            try await session.perform { try await $0.rename(temporary, to: destination.path, exclusive: true) }
            return destination
        } catch {
            await session.discardTemporary(temporary)
            throw error
        }
    }

    static func stage(_ data: Data) throws {
        // Called only for a newly confirmed restore with no live pending marker.
        // A kill between arming and marking must not block the user's next import.
        try removePending()
        try removePrepared()
        _ = try write(data, name: preparedName)
    }

    /// The success card's OK is the only operation that arms a startup restore.
    static func arm() throws {
        guard let (directory, _) = try openDirectory(create: false) else { throw FilaFailure(errno: ENOENT) }
        defer { close(directory) }
        guard renameatx_np(directory, preparedName, directory, pendingName, UInt32(RENAME_EXCL)) == 0 else {
            throw FilaFailure(errno: errno)
        }
        guard fsync(directory) == 0 else {
            let code = errno
            unlinkat(directory, pendingName, 0)
            throw FilaFailure(errno: code)
        }
    }

    static func removePrepared() throws {
        try remove(preparedName)
    }

    static func pending() throws -> Data? {
        guard let (directory, _) = try openDirectory(create: false) else { return nil }
        defer { close(directory) }
        let file = openat(directory, pendingName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw FilaFailure(errno: errno)
        }
        return try DescriptorIO.readAndClose(file, limit: ConfigurationBackup.maximumFileSize + 1)
    }

    static func removePending() throws {
        try remove(pendingName)
    }

    private static func remove(_ name: String) throws {
        guard let (directory, _) = try openDirectory(create: false) else { return }
        defer { close(directory) }
        guard unlinkat(directory, name, 0) == 0 else {
            if errno == ENOENT { return }
            throw FilaFailure(errno: errno)
        }
        guard fsync(directory) == 0 else { throw FilaFailure(errno: errno) }
    }

    private static func write(_ data: Data, name: String) throws -> URL {
        guard data.count <= ConfigurationBackup.maximumFileSize else { throw ConfigurationBackupFailure.tooLarge }
        guard let (directory, url) = try openDirectory(create: true) else { throw FilaFailure(errno: ENOENT) }
        defer { close(directory) }
        let temporary = ".\(UUID().uuidString).tmp"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw FilaFailure(errno: errno) }
        defer {
            close(file)
            unlinkat(directory, temporary, 0)
        }
        // Saved paths are private, even when Documents is exposed to Files.
        guard fchmod(file, mode_t(0o600)) == 0 else { throw FilaFailure(errno: errno) }
        try writeBytes(data, to: file)
        // Never overwrite a previous backup or a pending restore.
        guard renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0 else {
            throw FilaFailure(errno: errno)
        }
        guard fsync(directory) == 0 else {
            let code = errno
            unlinkat(directory, name, 0)
            throw FilaFailure(errno: code)
        }
        return url.appendingPathComponent(name)
    }

    private static func openDirectory(create: Bool) throws -> (Int32, URL)? {
        let manager = FileManager.default
        let proposed = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: create,
        )
        // Foundation can retain /var aliases in a non-sandboxed process. Resolve
        // with realpath before O_NOFOLLOW_ANY, retaining the pinned-path guard.
        let base: String
        do { base = try canonicalPath(proposed.path) }
        catch let error as FilaFailure where !create && error.systemError == ENOENT { return nil }
        let home = try canonicalPath(NSHomeDirectory())
        guard base.hasPrefix(home + "/") else { throw FilaFailure(errno: EACCES) }
        let parent = Darwin.open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else { throw FilaFailure(errno: errno) }
        defer { close(parent) }
        guard let namespace = try openChild("wiki.qaq.fila", in: parent, create: create) else { return nil }
        defer { close(namespace) }
        guard let directory = try openChild("Configuration Restore", in: namespace, create: create) else { return nil }
        let url = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("wiki.qaq.fila", isDirectory: true)
            .appendingPathComponent("Configuration Restore", isDirectory: true)
        return (directory, url)
    }

    private static func canonicalPath(_ path: String) throws -> String {
        guard !path.utf8.contains(0) else { throw FilaFailure(errno: EINVAL) }
        guard let resolved = realpath(path, nil) else { throw FilaFailure(errno: errno) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func openChild(_ name: String, in parent: Int32, create: Bool) throws -> Int32? {
        if create, mkdirat(parent, name, mode_t(0o700)) != 0, errno != EEXIST {
            throw FilaFailure(errno: errno)
        }
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            if !create, errno == ENOENT { return nil }
            throw FilaFailure(errno: errno)
        }
        var status = stat()
        guard fstat(directory, &status) == 0, status.st_uid == geteuid() else {
            close(directory)
            throw FilaFailure(errno: EACCES)
        }
        return directory
    }

    private static func writeBytes(_ data: Data, to file: Int32) throws {
        var status = stat()
        guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else {
            throw FilaFailure(errno: EINVAL)
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file, base.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw FilaFailure(errno: count == 0 ? EIO : errno) }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw FilaFailure(errno: errno) }
    }
}
