// ConfigFileUtils.swift
// Calyx

import Foundation

enum ConfigFileError: Error, LocalizedError, Sendable {
    case symlinkDetected
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .symlinkDetected:
            return "The config path is a symlink, which is not allowed for security reasons"
        case .writeFailed(let reason):
            return "Failed to write config file: \(reason)"
        }
    }
}

struct ConfigFileUtils: Sendable {

    static func isSymlink(at path: String) -> Bool {
        var statBuf = stat()
        guard lstat(path, &statBuf) == 0 else { return false }
        return (statBuf.st_mode & S_IFMT) == S_IFLNK
    }

    static func atomicWrite(data: Data, to path: String, lockPath: String) throws {
        let lockFd = open(lockPath, O_WRONLY | O_CREAT, 0o600)
        guard lockFd >= 0 else {
            throw ConfigFileError.writeFailed("Cannot create lock file")
        }
        defer {
            flock(lockFd, LOCK_UN)
            close(lockFd)
        }

        guard flock(lockFd, LOCK_EX) == 0 else {
            throw ConfigFileError.writeFailed("Cannot acquire lock")
        }

        let tempPath = path + ".tmp"

        try data.write(to: URL(fileURLWithPath: tempPath))
        chmod(tempPath, 0o600)

        guard rename(tempPath, path) == 0 else {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw ConfigFileError.writeFailed("Rename failed")
        }

        chmod(path, 0o600)
    }
}
