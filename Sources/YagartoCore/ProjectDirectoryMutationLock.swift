// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

@_silgen_name("flock")
private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

final class ProjectDirectoryMutationLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(_ directory: URL) throws -> ProjectDirectoryMutationLock {
        let canonicalDirectory = directory
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let descriptor = canonicalDirectory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        }
        guard descriptor >= 0 else {
            throw ProjectDirectoryLockError.failed(
                canonicalDirectory.path,
                String(cString: strerror(errno))
            )
        }

        while systemFlock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let detail = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw ProjectDirectoryLockError.failed(canonicalDirectory.path, detail)
        }
        return ProjectDirectoryMutationLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = systemFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

private enum ProjectDirectoryLockError: Error, LocalizedError {
    case failed(String, String)

    var errorDescription: String? {
        switch self {
        case .failed(let path, let detail):
            return "无法锁定工程目录 \(path)：\(detail)"
        }
    }
}
