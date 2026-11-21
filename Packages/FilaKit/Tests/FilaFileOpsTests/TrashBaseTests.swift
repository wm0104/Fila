@testable import FilaFileOps
import Foundation
import Testing

@Suite("Daemon trash bases")
struct TrashBaseTests {
    @Test
    func `Rootful relocated and confined operations retain their original trash bases`() throws {
        let scratch = Scratch()
        let bootstrap = scratch.directory("bootstrap")
        let confined = scratch.directory("confined")
        #expect(try FileOperations(bootstrapRoot: "").trashBase(volumeMountPoint: scratch.root) == scratch.root)
        #expect(try FileOperations(bootstrapRoot: bootstrap).trashBase(volumeMountPoint: "/") == bootstrap)
        #expect(try FileOperations(bootstrapRoot: "", writableRoot: confined).trashBase(volumeMountPoint: "/") == confined)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: scratch.root)) == ["bootstrap", "confined"])
    }
}
