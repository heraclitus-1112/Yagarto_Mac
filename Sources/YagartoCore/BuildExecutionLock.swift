// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

final class BuildExecutionLock {
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        guard descriptor >= 0 else { return }
        var unlock = flock()
        unlock.l_type = Int16(F_UNLCK)
        unlock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_SETLK, &unlock)
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

extension ProjectPathGuard {
    static func acquireBuildExecutionLock(
        profile: ProfileID,
        projectDirectory: URL,
        outputDirectory: URL
    ) throws -> BuildExecutionLock {
        let project = projectDirectory.standardizedFileURL
        let output = outputDirectory.standardizedFileURL
        let buildRoot = project
            .appendingPathComponent(".yagarto", isDirectory: true)
            .appendingPathComponent("build", isDirectory: true)
            .standardizedFileURL
        guard output.deletingLastPathComponent() == buildRoot,
              output.lastPathComponent == profile.rawValue else {
            throw YagartoError.pathTraversal(output.path)
        }

        try createOutputDirectory(
            projectDirectory: project,
            outputDirectory: buildRoot
        )
        try validateOutputHierarchy(
            projectDirectory: project,
            outputDirectory: buildRoot
        )

        let lockFile = buildRoot.appendingPathComponent(
            ".\(profile.rawValue).lock",
            isDirectory: false
        )
        let descriptor = lockFile.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw YagartoError.unsafeBuildLock(
                lockFile.path,
                String(cString: strerror(errno))
            )
        }
        var shouldClose = true
        defer {
            if shouldClose { _ = Darwin.close(descriptor) }
        }

        var descriptorMetadata = stat()
        guard Darwin.fstat(descriptor, &descriptorMetadata) == 0,
              (descriptorMetadata.st_mode & S_IFMT) == S_IFREG,
              descriptorMetadata.st_nlink == 1,
              descriptorMetadata.st_uid == geteuid() else {
            throw YagartoError.unsafeBuildLock(
                lockFile.path,
                "锁必须是当前用户拥有的单链接普通文件。"
            )
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw YagartoError.unsafeBuildLock(
                lockFile.path,
                String(cString: strerror(errno))
            )
        }
        guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw YagartoError.unsafeBuildLock(
                lockFile.path,
                String(cString: strerror(errno))
            )
        }

        var exclusiveLock = flock()
        exclusiveLock.l_type = Int16(F_WRLCK)
        exclusiveLock.l_whence = Int16(SEEK_SET)
        while Darwin.fcntl(descriptor, F_SETLKW, &exclusiveLock) == -1 {
            guard errno == EINTR else {
                throw YagartoError.unsafeBuildLock(
                    lockFile.path,
                    String(cString: strerror(errno))
                )
            }
        }

        var namedMetadata = stat()
        let namedResult = lockFile.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &namedMetadata)
        }
        guard namedResult == 0,
              namedMetadata.st_dev == descriptorMetadata.st_dev,
              namedMetadata.st_ino == descriptorMetadata.st_ino,
              (namedMetadata.st_mode & S_IFMT) == S_IFREG,
              namedMetadata.st_nlink == 1,
              namedMetadata.st_uid == geteuid(),
              (namedMetadata.st_mode & 0o777) == 0o600 else {
            throw YagartoError.unsafeBuildLock(
                lockFile.path,
                "锁路径在等待期间发生变化或权限不安全。"
            )
        }

        shouldClose = false
        return BuildExecutionLock(descriptor: descriptor)
    }
}
