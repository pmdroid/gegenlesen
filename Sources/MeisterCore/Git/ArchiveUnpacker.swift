import CLibArchive
import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if canImport(Darwin)
private func posixOpen(_ path: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32 {
    Darwin.open(path, oflag, mode)
}
private func posixWrite(_ fd: Int32, _ buf: UnsafeRawPointer!, _ nbyte: Int) -> Int {
    Darwin.write(fd, buf, nbyte)
}
private func posixClose(_ fd: Int32) -> Int32 { Darwin.close(fd) }
private func posixFchmod(_ fd: Int32, _ mode: mode_t) -> Int32 { Darwin.fchmod(fd, mode) }
private func posixLchown(_ path: UnsafePointer<CChar>, _ uid: uid_t, _ gid: gid_t) -> Int32 {
    Darwin.lchown(path, uid, gid)
}
private func posixLseek(_ fd: Int32, _ offset: off_t, _ whence: Int32) -> off_t {
    Darwin.lseek(fd, offset, whence)
}
private func posixFtruncate(_ fd: Int32, _ length: off_t) -> Int32 {
    Darwin.ftruncate(fd, length)
}
#else
private func posixOpen(_ path: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32 {
    Glibc.open(path, oflag, mode)
}
private func posixWrite(_ fd: Int32, _ buf: UnsafeRawPointer!, _ nbyte: Int) -> Int {
    Glibc.write(fd, buf, nbyte)
}
private func posixClose(_ fd: Int32) -> Int32 { Glibc.close(fd) }
private func posixFchmod(_ fd: Int32, _ mode: mode_t) -> Int32 { Glibc.fchmod(fd, mode) }
private func posixLchown(_ path: UnsafePointer<CChar>, _ uid: uid_t, _ gid: gid_t) -> Int32 {
    Glibc.lchown(path, uid, gid)
}
private func posixLseek(_ fd: Int32, _ offset: off_t, _ whence: Int32) -> off_t {
    Glibc.lseek(fd, offset, whence)
}
private func posixFtruncate(_ fd: Int32, _ length: off_t) -> Int32 {
    Glibc.ftruncate(fd, length)
}
#endif

public enum ArchiveError: Error, Equatable, Sendable {
    case zipRejected
    case unsupportedEntry(String)
    case hardlink
    case unsafePath(String)
    case unsafeSymlink(String)
    case pathTooLong
    case tooManyFiles
    case archiveTooLarge
    case fileTooLarge(String)
    case setidBit
    case readFailed(String)
    case writeFailed(String)
    case chownFailed(String)
}

public struct ArchiveUnpacker: Sendable {
    public static let maxFileCount = 50_000
    public static let maxUncompressedBytes = 2_147_483_648
    public static let maxRegularFileBytes = 67_108_864

    public init() {}

    public func unpack(archive: URL, into workspace: URL) throws {
        let gzip = try Self.sniff(archive)
        try walk(archive: archive, gzip: gzip, write: false, workspace: workspace)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try walk(archive: archive, gzip: gzip, write: true, workspace: workspace)
        try applyOwnership(workspace)
    }

    static func sniff(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 2) ?? Data()
        if prefix.count >= 2, prefix[0] == 0x50, prefix[1] == 0x4B {
            throw ArchiveError.zipRejected
        }
        return prefix.count >= 2 && prefix[0] == 0x1F && prefix[1] == 0x8B
    }

    private func walk(archive: URL, gzip: Bool, write: Bool, workspace: URL) throws {
        let handle: OpaquePointer = try archive.path.withCString { path in
            guard let opened = meister_archive_open(path, gzip ? 1 : 0) else {
                throw ArchiveError.readFailed("unable to open archive")
            }
            return opened
        }
        defer { meister_archive_close(handle) }

        var fileCount = 0
        var uncompressed: Int64 = 0

        while true {
            let status = meister_archive_next_header(handle)
            if status == 0 {
                break
            }
            if status < 0 {
                throw ArchiveError.readFailed(cError(handle))
            }
            try processEntry(
                handle,
                write: write,
                workspace: workspace,
                fileCount: &fileCount,
                uncompressed: &uncompressed
            )
        }
    }

    private func processEntry(
        _ handle: OpaquePointer,
        write: Bool,
        workspace: URL,
        fileCount: inout Int,
        uncompressed: inout Int64
    ) throws {
        guard let rawPath = meister_archive_pathname(handle) else {
            throw ArchiveError.unsafePath("")
        }
        let pathname = String(cString: rawPath)
        fileCount += 1
        if fileCount > Self.maxFileCount {
            throw ArchiveError.tooManyFiles
        }

        let rawSize = meister_archive_size(handle)
        let declared: Int64 = rawSize > 0 ? rawSize : 0
        if declared > Int64(Self.maxRegularFileBytes) {
            throw ArchiveError.fileTooLarge(pathname)
        }
        if uncompressed > Int64(Self.maxUncompressedBytes) - declared {
            throw ArchiveError.archiveTooLarge
        }

        if ArchivePath.isSkippedEntry(pathname) {
            try consumeData(handle, fd: nil, path: pathname, uncompressed: &uncompressed)
            return
        }

        let relative = try ArchivePath.normalizedRelative(pathname)
        if let hardlink = meister_archive_hardlink(handle), hardlink.pointee != 0 {
            throw ArchiveError.hardlink
        }

        let mode = meister_archive_mode(handle)
        if mode & (S_ISUID | S_ISGID) != 0 {
            throw ArchiveError.setidBit
        }

        let type = meister_archive_filetype(handle)
        let kind: EntryKind
        switch type {
        case Int32(MEISTER_AE_IFREG):
            kind = .file
        case Int32(MEISTER_AE_IFDIR):
            kind = .directory
        case Int32(MEISTER_AE_IFLNK):
            kind = .symlink
        default:
            throw ArchiveError.unsupportedEntry(pathname)
        }

        if kind == .symlink {
            let target = meister_archive_symlink(handle).map { String(cString: $0) } ?? ""
            _ = try ArchivePath.symlinkDestination(
                workspace: workspace,
                linkRelative: relative,
                target: target
            )
        }

        if write {
            try writeEntry(
                handle,
                kind: kind,
                relative: relative,
                workspace: workspace,
                uncompressed: &uncompressed
            )
        } else {
            try consumeData(handle, fd: nil, path: relative, uncompressed: &uncompressed)
        }
    }

    private enum EntryKind {
        case file, directory, symlink
    }

    private func writeEntry(
        _ handle: OpaquePointer,
        kind: EntryKind,
        relative: String,
        workspace: URL,
        uncompressed: inout Int64
    ) throws {
        guard let dest = ArchivePath.containedURL(root: workspace, relative: relative) else {
            throw ArchiveError.unsafePath(relative)
        }
        let fm = FileManager.default
        switch kind {
        case .directory:
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            try consumeData(handle, fd: nil, path: relative, uncompressed: &uncompressed)
        case .symlink:
            let parent = dest.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let target = meister_archive_symlink(handle).map { String(cString: $0) } ?? ""
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.createSymbolicLink(atPath: dest.path, withDestinationPath: target)
            try consumeData(handle, fd: nil, path: relative, uncompressed: &uncompressed)
        case .file:
            let parent = dest.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try writeRegularFile(handle, to: dest, path: relative, uncompressed: &uncompressed)
        }
    }

    @discardableResult
    private func consumeData(
        _ handle: OpaquePointer,
        fd: Int32?,
        path: String,
        uncompressed: inout Int64
    ) throws -> Int64 {
        var expanded: Int64 = 0
        while true {
            var buf: UnsafeRawPointer?
            var size: Int = 0
            var offset: Int64 = 0
            let status = withUnsafeMutablePointer(to: &buf) { bufPtr in
                meister_archive_read_data_block(handle, bufPtr, &size, &offset)
            }
            if status == 0 {
                if let fd, posixFtruncate(fd, off_t(expanded)) != 0 {
                    throw ArchiveError.writeFailed(path)
                }
                if uncompressed > Int64(Self.maxUncompressedBytes) - expanded {
                    throw ArchiveError.archiveTooLarge
                }
                uncompressed += expanded
                return expanded
            }
            if status < 0 {
                throw ArchiveError.readFailed(cError(handle))
            }
            let end = offset + Int64(size)
            if end < offset {
                throw ArchiveError.archiveTooLarge
            }
            if end > expanded {
                expanded = end
            }
            if expanded > Int64(Self.maxRegularFileBytes) {
                throw ArchiveError.fileTooLarge(path)
            }
            if uncompressed > Int64(Self.maxUncompressedBytes) - expanded {
                throw ArchiveError.archiveTooLarge
            }
            guard let fd, let buf, size > 0 else {
                continue
            }
            if posixLseek(fd, off_t(offset), SEEK_SET) < 0 {
                throw ArchiveError.writeFailed(path)
            }
            var written = 0
            let bytes = buf.assumingMemoryBound(to: UInt8.self)
            while written < size {
                let n = posixWrite(fd, bytes.advanced(by: written), size - written)
                if n < 0 {
                    throw ArchiveError.writeFailed(path)
                }
                written += n
            }
        }
    }

    private func writeRegularFile(
        _ handle: OpaquePointer,
        to dest: URL,
        path: String,
        uncompressed: inout Int64
    ) throws {
        let fd = dest.path.withCString { path in
            posixOpen(path, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o644)
        }
        guard fd >= 0 else {
            throw ArchiveError.writeFailed(dest.path)
        }
        defer { _ = posixClose(fd) }
        _ = posixFchmod(fd, 0o644)
        try consumeData(handle, fd: fd, path: path, uncompressed: &uncompressed)
    }

    private func applyOwnership(_ workspace: URL) throws {
        #if os(Linux)
        try chownTree(workspace, required: true)
        #else
        try chownTree(workspace, required: false)
        #endif
    }

    private func chownTree(_ root: URL, required: Bool) throws {
        let uid: uid_t = 1000
        let gid: gid_t = 1000
        try chownPath(root.path, uid: uid, gid: gid, required: required)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }
        for case let url as URL in enumerator {
            try chownPath(url.path, uid: uid, gid: gid, required: required)
        }
    }

    private func chownPath(_ path: String, uid: uid_t, gid: gid_t, required: Bool) throws {
        let result = path.withCString { posixLchown($0, uid, gid) }
        if result == 0 {
            return
        }
        let code = errno
        if !required, code == EPERM || code == ENOTSUP {
            return
        }
        throw ArchiveError.chownFailed(path)
    }

    private func cError(_ handle: OpaquePointer) -> String {
        if let message = meister_archive_error_string(handle) {
            return String(cString: message)
        }
        return "unknown archive error"
    }
}
