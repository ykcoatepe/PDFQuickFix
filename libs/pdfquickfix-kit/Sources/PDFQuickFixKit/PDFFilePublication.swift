import Darwin
import Foundation

/// Publication of a validated, privately staged file on the destination filesystem.
public enum PDFFilePublication {
    public struct PublishedFile {
        public let url: URL
        private let device: dev_t
        private let inode: ino_t
        private let birthSeconds: Int
        private let birthNanoseconds: Int
        private let size: off_t
        private let modificationSeconds: Int
        private let modificationNanoseconds: Int

        fileprivate init(url: URL, status: stat) {
            self.url = url
            device = status.st_dev
            inode = status.st_ino
            birthSeconds = status.st_birthtimespec.tv_sec
            birthNanoseconds = status.st_birthtimespec.tv_nsec
            size = status.st_size
            modificationSeconds = status.st_mtimespec.tv_sec
            modificationNanoseconds = status.st_mtimespec.tv_nsec
        }

        /// Roll back only the published file, preserving any replacement at its path.
        @discardableResult
        public func removeIfUnchanged() throws -> Bool {
            let recoveryDirectory = url.deletingLastPathComponent()
                .appendingPathComponent(".pdfquickfix-recovery-\(UUID().uuidString)")
            let quarantined = recoveryDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw PublicationError.recoveryRequired([url])
            }
            // Remove only an empty recovery directory; retained candidates must survive.
            defer { _ = rmdir(recoveryDirectory.path) }
            guard renamex_np(url.path, quarantined.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == ENOENT { return false }
                throw PublicationError.recoveryRequired([url])
            }
            var status = stat()
            let isUnchanged = lstat(quarantined.path, &status) == 0
                && status.st_dev == device && status.st_ino == inode
                && status.st_birthtimespec.tv_sec == birthSeconds
                && status.st_birthtimespec.tv_nsec == birthNanoseconds
                && status.st_size == size
                && status.st_mtimespec.tv_sec == modificationSeconds
                && status.st_mtimespec.tv_nsec == modificationNanoseconds
            if isUnchanged {
                guard unlink(quarantined.path) == 0 else {
                    throw PublicationError.recoveryRequired([quarantined])
                }
                return true
            }
            guard renamex_np(quarantined.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
                throw PublicationError.recoveryRequired([quarantined])
            }
            return false
        }
    }

    public enum PublicationError: LocalizedError {
        case sameFile(URL)
        case destinationExists(URL)
        case recoveryRequired([URL])

        public var errorDescription: String? {
            switch self {
            case let .sameFile(url):
                "Output must differ from the original file: \(url.lastPathComponent)"
            case let .destinationExists(url):
                "Output already exists: \(url.lastPathComponent)"
            case let .recoveryRequired(urls):
                "Rollback retained files for recovery: \(urls.map(\.path).joined(separator: ", "))"
            }
        }
    }

    public static func areSameFile(_ first: URL, _ second: URL) throws -> Bool {
        let first = first.standardizedFileURL.resolvingSymlinksInPath()
        let second = second.standardizedFileURL.resolvingSymlinksInPath()
        if first == second { return true }
        var firstStat = stat()
        var secondStat = stat()
        guard stat(first.path, &firstStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard stat(second.path, &secondStat) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return firstStat.st_dev == secondStat.st_dev && firstStat.st_ino == secondStat.st_ino
    }

    public static func requireDistinct(input: URL, output: URL) throws {
        if try areSameFile(input, output) {
            throw PublicationError.sameFile(output)
        }
    }

    /// Atomically moves the staged file. Exclusive rename refuses a destination
    /// created concurrently without requiring filesystem hard-link support.
    @discardableResult
    public static func publish(staged: URL, to destination: URL, overwrite: Bool) throws -> PublishedFile {
        var status = stat()
        guard lstat(staged.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let result = overwrite
            ? rename(staged.path, destination.path)
            : renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL))
        guard result == 0 else {
            let code = errno
            if code == EEXIST { throw PublicationError.destinationExists(destination) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return PublishedFile(url: destination, status: status)
    }
}
