import Foundation
import Testing
@testable import MeisterCore

@Suite
struct ArchiveUnpackerTests {
    @Test
    func extractsRegularFilesAndRelativeSymlinks() throws {
        try withTempDir("meister-unpack-ok") { dir in
            let tree = dir.appendingPathComponent("tree")
            try writeFile("hello.txt", "hi\n", in: tree)
            try FileManager.default.createSymbolicLink(
                atPath: tree.appendingPathComponent("link").path,
                withDestinationPath: "hello.txt"
            )
            try writeFile("nested.tar", "blob", in: tree)
            try writeFile(".DS_Store", "skip-me", in: tree)
            try writeFile("._hidden", "skip-me", in: tree)
            let archive = dir.appendingPathComponent("ok.tar")
            try bsdtarCreate(from: tree, to: archive)
            let dest = dir.appendingPathComponent("out")
            try ArchiveUnpacker().unpack(archive: archive, into: dest)
            #expect(try String(contentsOf: dest.appendingPathComponent("hello.txt")) == "hi\n")
            #expect(try String(contentsOf: dest.appendingPathComponent("nested.tar")) == "blob")
            #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent(".DS_Store").path))
            #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("._hidden").path))
            let destLink = dest.appendingPathComponent("link")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destLink.path) == "hello.txt")
        }
    }

    @Test
    func acceptsPaxLongNameWhenFinalPathIsValid() throws {
        try withTempDir("meister-unpack-pax") { dir in
            let tree = dir.appendingPathComponent("tree")
            let longName = String(repeating: "a", count: 180) + ".txt"
            try writeFile(longName, "pax-ok\n", in: tree)
            let archive = dir.appendingPathComponent("pax.tar")
            try bsdtarCreate(from: tree, to: archive, format: "pax")
            let dest = dir.appendingPathComponent("out")
            try ArchiveUnpacker().unpack(archive: archive, into: dest)
            #expect(try String(contentsOf: dest.appendingPathComponent(longName)) == "pax-ok\n")
        }
    }

    @Test
    func rejectsAbsoluteSymlink() throws {
        try withTempDir("meister-unpack-abslink") { dir in
            let tree = dir.appendingPathComponent("tree")
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: tree.appendingPathComponent("link").path,
                withDestinationPath: "/etc/passwd"
            )
            let archive = dir.appendingPathComponent("abs.tar")
            try bsdtarCreate(from: tree, to: archive)
            let dest = dir.appendingPathComponent("out")
            #expect(throws: ArchiveError.unsafeSymlink("/etc/passwd")) {
                try ArchiveUnpacker().unpack(archive: archive, into: dest)
            }
            #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("link").path))
        }
    }

    @Test
    func rejectsHardlink() throws {
        try withTempDir("meister-unpack-hardlink") { dir in
            let body = Data("same\n".utf8)
            let padded = body + Data(count: 512 - body.count)
            let archiveBytes = ustarArchive(
                ustarHeader(name: "a.txt", size: body.count),
                padded,
                ustarHeader(name: "b.txt", size: 0, typeflag: 0x31, linkname: "a.txt")
            )
            let archive = dir.appendingPathComponent("hard.tar")
            try archiveBytes.write(to: archive)
            #expect(throws: ArchiveError.hardlink) {
                try ArchiveUnpacker().unpack(
                    archive: archive,
                    into: dir.appendingPathComponent("out")
                )
            }
        }
    }

    @Test
    func rejectsFifo() throws {
        try withTempDir("meister-unpack-fifo") { dir in
            let archive = dir.appendingPathComponent("fifo.tar")
            try ustarArchive(ustarHeader(name: "pipe", size: 0, typeflag: 0x36)).write(to: archive)
            do {
                try ArchiveUnpacker().unpack(
                    archive: archive,
                    into: dir.appendingPathComponent("out")
                )
                Issue.record("expected fifo to be rejected")
            } catch ArchiveError.unsupportedEntry(let path) {
                #expect(path.contains("pipe"))
            }
        }
    }

    @Test
    func rejectsZipMagic() throws {
        try withTempDir("meister-unpack-zip") { dir in
            let archive = dir.appendingPathComponent("x.zip")
            try Data([0x50, 0x4B, 0x03, 0x04, 0x00]).write(to: archive)
            #expect(throws: ArchiveError.zipRejected) {
                try ArchiveUnpacker().unpack(
                    archive: archive,
                    into: dir.appendingPathComponent("out")
                )
            }
        }
    }

    @Test
    func rejectsGzipBombPastTwoGiB() throws {
        try withTempDir("meister-unpack-bomb") { dir in
            let header = ustarHeader(name: "bomb.bin", size: 2_147_483_649)
            let tar = header + Data(count: 1024)
            let gz = try gzip(tar)
            #expect(gz.count < 1_000)
            let archive = dir.appendingPathComponent("bomb.tar.gz")
            try gz.write(to: archive)
            #expect(throws: ArchiveError.self) {
                try ArchiveUnpacker().unpack(
                    archive: archive,
                    into: dir.appendingPathComponent("out")
                )
            }
        }
    }

    @Test
    func darwinChownFailureDoesNotFailExtract() throws {
        try withTempDir("meister-unpack-chown") { dir in
            let tree = dir.appendingPathComponent("tree")
            try writeFile("ok.txt", "ok\n", in: tree)
            let archive = dir.appendingPathComponent("ok.tar.gz")
            try gzipTarCreate(from: tree, to: archive)
            let dest = dir.appendingPathComponent("out")
            try ArchiveUnpacker().unpack(archive: archive, into: dest)
            #expect(try String(contentsOf: dest.appendingPathComponent("ok.txt")) == "ok\n")
        }
    }
}
