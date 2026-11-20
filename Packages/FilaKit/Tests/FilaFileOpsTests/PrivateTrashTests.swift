import Darwin
@testable import FilaFileOps
import FilaProtocol
import Foundation
import Testing

@Suite("Private in-process trash")
struct PrivateTrashTests {
    @Test
    func `Configured trash reuses real delete restore and empty with recovery metadata`() throws {
        let scratch = Scratch()
        let base = scratch.path("Application Support/wiki.qaq.fila/Trash")
        let operations = FileOperations(bootstrapRoot: "", privateTrashBase: base)
        let run = { (request: JobRequest) in FileJob(request: request, operations: operations).run { _ in } }
        let original = scratch.file("payload", contents: "keep bytes", mode: 0o640)
        let identity = UUID()
        let trash = FilaTrash.directory(under: base)
        #expect(!exists(base), "Constructing the backend does not create directories")
        #expect(run(JobRequest(kind: .delete, sources: [original], useTrash: true, trashID: identity)).code == .success)
        #expect(!exists(original))
        #expect(permissions(of: base) == 0o700)
        #expect(permissions(of: trash) == 0o700)
        #expect(metadata(of: base)?.st_uid == geteuid())
        #expect(extendedAttribute(FilaTrash.originAttribute, at: trash + "/payload") == original)
        #expect(extendedAttribute(FilaTrash.jobAttribute, at: trash + "/payload") == identity.uuidString)
        #expect(run(JobRequest(kind: .restore, sources: [trash + "/payload"], trashID: identity)).code == .success)
        #expect(try String(contentsOfFile: original, encoding: .utf8) == "keep bytes")
        #expect(permissions(of: original) == 0o640)
        #expect(extendedAttribute(FilaTrash.originAttribute, at: original) == nil)
        #expect(run(JobRequest(kind: .delete, sources: [original], useTrash: true)).code == .success)
        #expect(run(JobRequest(kind: .delete, sources: [trash + "/payload"])).code == .success)
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base) == [FilaTrash.directoryName])
    }

    @Test(arguments: ["base-link", "trash-link", "base-mode", "trash-mode", "ancestor-mode"])
    func `Unsafe private trash refuses without changing the source`(fault: String) throws {
        let scratch = Scratch()
        let parent = scratch.directory("parent")
        let base = scratch.path("parent/private")
        let trash = FilaTrash.directory(under: base)
        let elsewhere = scratch.directory("elsewhere")
        if fault == "base-link" {
            #expect(symlink(elsewhere, base) == 0)
        } else {
            #expect(mkdir(base, 0o700) == 0)
            if fault == "trash-link" { #expect(symlink(elsewhere, trash) == 0) }
            if fault == "base-mode" { #expect(chmod(base, 0o755) == 0) }
            if fault == "trash-mode" { #expect(mkdir(trash, 0o755) == 0) }
            if fault == "ancestor-mode" { #expect(chmod(parent, 0o777) == 0) }
        }
        defer { chmod(parent, 0o755) }
        let source = scratch.file("payload", contents: "untouched")
        let result = FileJob(request: JobRequest(kind: .delete, sources: [source], useTrash: true), operations: FileOperations(bootstrapRoot: "", privateTrashBase: base)).run { _ in }
        #expect(result.code != .success)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "untouched")
        #expect(extendedAttribute(FilaTrash.originAttribute, at: source) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere).isEmpty)
        if fault == "base-mode" { #expect(permissions(of: base) == 0o755) }
        if fault == "trash-mode" { #expect(permissions(of: trash) == 0o755) }
    }

    @Test(.enabled(if: geteuid() == 0))
    func `A different owner is refused rather than repaired`() throws {
        let scratch = Scratch()
        let base = scratch.directory("private")
        #expect(chmod(base, 0o700) == 0)
        #expect(chown(base, 501, 501) == 0)
        let source = scratch.file("payload")
        let result = FileJob(request: JobRequest(kind: .delete, sources: [source], useTrash: true), operations: FileOperations(bootstrapRoot: "", privateTrashBase: base)).run { _ in }
        #expect(result.code != .success)
        #expect(exists(source))
        #expect(metadata(of: base)?.st_uid == 501)
    }

    @Test
    func `ACL bearing private directories are refused before moving the source`() throws {
        let scratch = Scratch()
        let base = scratch.directory("private")
        #expect(chmod(base, 0o700) == 0)
        var acl = acl_init(1)
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        try #require(acl_create_entry(&acl, &entry) == 0)
        let access = try #require(entry)
        var identity = try #require(UUID(uuidString: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000")?.uuid)
        try #require(acl_set_tag_type(access, ACL_EXTENDED_ALLOW) == 0)
        try #require(acl_set_qualifier(access, &identity) == 0)
        try #require(acl_set_permset_mask_np(access, UInt64(ACL_READ_DATA.rawValue)) == 0)
        try #require(acl_set_file(base, ACL_TYPE_EXTENDED, acl) == 0)
        let source = scratch.file("payload", contents: "kept")
        let result = FileJob(request: JobRequest(kind: .delete, sources: [source], useTrash: true), operations: FileOperations(bootstrapRoot: "", privateTrashBase: base)).run { _ in }
        #expect(result.systemError == EACCES)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "kept")
    }

    @Test
    func `Configured trash keeps restore origin and collision guards`() throws {
        let scratch = Scratch()
        let base = scratch.path("private")
        let operations = FileOperations(bootstrapRoot: "", privateTrashBase: base)
        let run = { (request: JobRequest) in FileJob(request: request, operations: operations).run { _ in } }
        let source = scratch.file("payload", contents: "original")
        let trash = FilaTrash.directory(under: base) + "/payload"
        #expect(run(JobRequest(kind: .delete, sources: [source], useTrash: true)).code == .success)
        scratch.file("payload", contents: "replacement")
        #expect(run(JobRequest(kind: .restore, sources: [trash], overwrite: true)).systemError == EEXIST)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "replacement")
        #expect(try String(contentsOfFile: trash, encoding: .utf8) == "original")
        let forged = scratch.file("forged")
        setExtendedAttribute(FilaTrash.originAttribute, to: scratch.path("absent"), at: forged)
        #expect(run(JobRequest(kind: .restore, sources: [forged])).code == .invalidRequest)
        #expect(exists(forged))
        #expect(!exists(scratch.path("absent")))
    }

    @Test
    func `Unsafe trash does not block a separately requested permanent delete`() throws {
        let scratch = Scratch()
        let base = scratch.directory("private")
        #expect(chmod(base, 0o700) == 0)
        let trash = FilaTrash.directory(under: base)
        #expect(mkdir(trash, 0o755) == 0)
        let source = scratch.file("payload", contents: "kept unless explicitly deleted")
        let operations = FileOperations(bootstrapRoot: "", privateTrashBase: base)
        let refused = FileJob(request: JobRequest(kind: .delete, sources: [source], useTrash: true), operations: operations).run { _ in }
        #expect(refused.systemError == EACCES)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "kept unless explicitly deleted")
        let explicit = FileJob(request: JobRequest(kind: .delete, sources: [source], useTrash: false), operations: operations).run { _ in }
        #expect(explicit.code == .success)
        #expect(!exists(source))
        #expect(permissions(of: trash) == 0o755)
        #expect(metadata(of: trash)?.st_uid == geteuid())
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash).isEmpty)
    }

    @Test
    func `Default daemon and confined backend retain their old trash bases`() throws {
        let scratch = Scratch()
        let bootstrap = scratch.directory("bootstrap")
        let confined = scratch.directory("confined")
        #expect(try FileOperations(bootstrapRoot: "").trashBase(volumeMountPoint: scratch.root) == scratch.root)
        #expect(try FileOperations(bootstrapRoot: bootstrap).trashBase(volumeMountPoint: "/") == bootstrap)
        #expect(try FileOperations(bootstrapRoot: "", writableRoot: confined, privateTrashBase: scratch.path("unused")).trashBase(volumeMountPoint: "/") == confined)
        #expect(!exists(scratch.path("unused")))
    }
}
