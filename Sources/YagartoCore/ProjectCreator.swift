// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

public struct ProjectCreationRequest: Equatable, Sendable {
    public let parentDirectory: URL
    public let name: String
    public let profile: ProfileID

    public init(parentDirectory: URL, name: String, profile: ProfileID) {
        self.parentDirectory = parentDirectory
        self.name = name
        self.profile = profile
    }
}

public struct ProjectImportRequest: Equatable, Sendable {
    public let inputs: [URL]
    public let profile: ProfileID

    public init(inputs: [URL], profile: ProfileID) {
        self.inputs = inputs
        self.profile = profile
    }
}

public struct CreatedProject: Equatable, Sendable {
    public let projectDirectory: URL
    public let sourceURL: URL
    public let configuration: ProjectConfiguration

    public init(projectDirectory: URL, sourceURL: URL, configuration: ProjectConfiguration) {
        self.projectDirectory = projectDirectory.standardizedFileURL
        self.sourceURL = sourceURL.standardizedFileURL
        self.configuration = configuration
    }
}

public enum ProjectImportStatus: String, Codable, Equatable, Sendable {
    case complete
    case partial
}

public struct ProjectImportIssue: Equatable, Sendable {
    public let sourceURL: URL
    public let code: String
    public let message: String

    public init(sourceURL: URL, code: String, message: String) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.code = code
        self.message = message
    }
}

public struct ProjectImportReport: Equatable, Sendable {
    public let schemaVersion: Int
    public let status: ProjectImportStatus
    public let profile: ProfileID
    public let created: [CreatedProject]
    public let skipped: [ProjectImportIssue]
    public let warnings: [ProjectImportIssue]

    public init(
        profile: ProfileID,
        created: [CreatedProject],
        skipped: [ProjectImportIssue],
        warnings: [ProjectImportIssue]
    ) {
        schemaVersion = 1
        status = skipped.isEmpty && warnings.isEmpty ? .complete : .partial
        self.profile = profile
        self.created = created
        self.skipped = skipped
        self.warnings = warnings
    }
}

enum ProjectCreationCheckpoint: CaseIterable, Sendable {
    case beforeSourceWrite
    case beforeConfigurationWrite
    case beforeValidation
    case beforePublish
}

public struct ProjectCreator: Sendable {
    public static let defaultMaximumFileBytes = 4 * 1_024 * 1_024

    private let maximumFileBytes: Int
    private let checkpoint: @Sendable (ProjectCreationCheckpoint, URL) throws -> Void
    private let beforeOriginalRemoval: @Sendable (URL) throws -> Void

    public init(maximumFileBytes: Int = ProjectCreator.defaultMaximumFileBytes) {
        self.maximumFileBytes = max(1, maximumFileBytes)
        checkpoint = { _, _ in }
        beforeOriginalRemoval = { _ in }
    }

    init(
        maximumFileBytes: Int = ProjectCreator.defaultMaximumFileBytes,
        testingBeforePublish: @escaping @Sendable (URL) throws -> Void
    ) {
        self.maximumFileBytes = max(1, maximumFileBytes)
        checkpoint = { phase, staging in
            if phase == .beforePublish { try testingBeforePublish(staging) }
        }
        beforeOriginalRemoval = { _ in }
    }

    init(
        maximumFileBytes: Int = ProjectCreator.defaultMaximumFileBytes,
        testingCheckpoint: @escaping @Sendable (ProjectCreationCheckpoint) throws -> Void
    ) {
        self.maximumFileBytes = max(1, maximumFileBytes)
        checkpoint = { phase, _ in try testingCheckpoint(phase) }
        beforeOriginalRemoval = { _ in }
    }

    init(
        maximumFileBytes: Int = ProjectCreator.defaultMaximumFileBytes,
        testingRemoveOriginal: @escaping @Sendable (URL) throws -> Void
    ) {
        self.maximumFileBytes = max(1, maximumFileBytes)
        checkpoint = { _, _ in }
        beforeOriginalRemoval = testingRemoveOriginal
    }

    init(
        maximumFileBytes: Int = ProjectCreator.defaultMaximumFileBytes,
        testingBeforeOriginalRemoval: @escaping @Sendable (URL) throws -> Void
    ) {
        self.maximumFileBytes = max(1, maximumFileBytes)
        checkpoint = { _, _ in }
        beforeOriginalRemoval = testingBeforeOriginalRemoval
    }

    public func create(_ request: ProjectCreationRequest) throws -> CreatedProject {
        let parent = try validatedDirectory(request.parentDirectory)
        try validateProjectName(request.name)

        for suffix in 1...10_000 {
            let directoryName = suffix == 1 ? request.name : "\(request.name)-\(suffix)"
            do {
                return try stageAndPublish(
                    parent: parent,
                    directoryName: directoryName,
                    sourceName: "\(directoryName).s",
                    sourceData: Data(template(for: request.profile).utf8),
                    profile: request.profile,
                    entry: defaultEntry(for: request.profile)
                )
            } catch PublishFailure.destinationExists {
                continue
            } catch let error as YagartoError {
                throw error
            } catch {
                throw YagartoError.projectCreationFailed(
                    parent.appendingPathComponent(directoryName).path,
                    error.localizedDescription
                )
            }
        }
        throw YagartoError.projectCreationFailed(parent.path, "无法分配唯一的工程目录名。")
    }

    public func importProjects(_ request: ProjectImportRequest) -> ProjectImportReport {
        let expansion = expandedSources(from: request.inputs)
        var created: [CreatedProject] = []
        var skipped = expansion.issues
        var warnings: [ProjectImportIssue] = []

        for source in expansion.sources {
            do {
                let result = try importSource(source, profile: request.profile)
                created.append(result.created)
                if let warning = result.warning {
                    warnings.append(warning)
                }
            } catch let failure as ImportFailure {
                skipped.append(ProjectImportIssue(
                    sourceURL: source,
                    code: failure.code,
                    message: failure.message
                ))
            } catch {
                skipped.append(ProjectImportIssue(
                    sourceURL: source,
                    code: "project.import_failed",
                    message: "导入失败：\(error.localizedDescription)"
                ))
            }
        }

        return ProjectImportReport(
            profile: request.profile,
            created: created,
            skipped: skipped,
            warnings: warnings
        )
    }

    private func importSource(_ source: URL, profile: ProfileID) throws -> ImportResult {
        let lexicalSource = source.standardizedFileURL
        let parent = lexicalSource.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let source = parent.appendingPathComponent(lexicalSource.lastPathComponent)
        let directoryLock: ProjectDirectoryMutationLock
        do {
            directoryLock = try ProjectDirectoryMutationLock.acquire(parent)
        } catch {
            throw ImportFailure(
                code: "project.directory_lock_failed",
                message: "无法锁定源码目录：\(error.localizedDescription)"
            )
        }
        defer { directoryLock.release() }
        let snapshot = try readSafeSource(source)
        guard let sourceText = String(data: snapshot.data, encoding: .utf8) else {
            throw ImportFailure(code: "project.invalid_utf8", message: "源码不是有效的 UTF-8 文本。")
        }
        guard !belongsToExistingProject(source) else {
            throw ImportFailure(code: "project.already_configured", message: "源码已经属于一个 YAGARTO 工程。")
        }
        let baseName = source.deletingPathExtension().lastPathComponent
        do {
            try validateProjectName(baseName)
        } catch {
            throw ImportFailure(code: "project.invalid_name", message: "源码文件名不能用作工程名。")
        }
        let entry = try detectedEntry(in: sourceText, sourceURL: source, profile: profile)
        for suffix in 1...10_000 {
            let directoryName = suffix == 1 ? baseName : "\(baseName)-\(suffix)"
            do {
                let created = try stageAndPublish(
                    parent: parent,
                    directoryName: directoryName,
                    sourceName: source.lastPathComponent,
                    sourceData: snapshot.data,
                    profile: profile,
                    entry: entry
                )
                return ImportResult(
                    created: created,
                    warning: removeOriginalIfUnchanged(source, snapshot: snapshot)
                )
            } catch PublishFailure.destinationExists {
                continue
            }
        }
        throw ImportFailure(code: "project.name_exhausted", message: "无法分配唯一的工程目录名。")
    }

    private func stageAndPublish(
        parent: URL,
        directoryName: String,
        sourceName: String,
        sourceData: Data,
        profile: ProfileID,
        entry: String
    ) throws -> CreatedProject {
        let finalDirectory = parent.appendingPathComponent(directoryName, isDirectory: true)
        if fileMetadata(finalDirectory) != nil {
            throw PublishFailure.destinationExists
        }

        let staging = try createPrivateStagingDirectory(in: parent)
        var published = false
        defer {
            if !published {
                try? FileManager.default.removeItem(at: staging)
            }
        }

        let stagedSource = staging.appendingPathComponent(sourceName)
        try checkpoint(.beforeSourceWrite, staging)
        try sourceData.write(to: stagedSource, options: [.atomic])
        let configuration = ProjectConfiguration(
            profile: profile,
            entry: entry,
            sources: [sourceName],
            outputName: directoryName
        )
        try checkpoint(.beforeConfigurationWrite, staging)
        try ConfigStore(projectDirectory: staging).save(configuration)
        try checkpoint(.beforeValidation, staging)
        guard try Data(contentsOf: stagedSource) == sourceData,
              try ConfigStore(projectDirectory: staging).load() == configuration else {
            throw YagartoError.projectCreationFailed(finalDirectory.path, "工程暂存校验失败。")
        }

        try checkpoint(.beforePublish, staging)
        try publishExclusively(staging: staging, destination: finalDirectory)
        published = true
        return CreatedProject(
            projectDirectory: finalDirectory,
            sourceURL: finalDirectory.appendingPathComponent(sourceName),
            configuration: configuration
        )
    }

    private func expandedSources(from inputs: [URL]) -> SourceExpansion {
        var sources: [URL] = []
        var issues: [ProjectImportIssue] = []
        var seen: Set<String> = []

        for rawInput in inputs {
            let input = rawInput.standardizedFileURL
            guard let metadata = fileMetadata(input) else {
                issues.append(ProjectImportIssue(
                    sourceURL: input,
                    code: "project.source_missing",
                    message: "找不到待导入的文件或目录。"
                ))
                continue
            }
            let kind = metadata.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFDIR) {
                do {
                    let children = try FileManager.default.contentsOfDirectory(
                        at: input,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                    let candidates = children
                        .filter(isAssemblyURL)
                        .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                    if candidates.isEmpty {
                        issues.append(ProjectImportIssue(
                            sourceURL: input,
                            code: "project.no_sources",
                            message: "目录当前层没有可导入的 .s 或 .S 文件。"
                        ))
                    }
                    for child in candidates {
                        if seen.insert(child.standardizedFileURL.path).inserted {
                            sources.append(child.standardizedFileURL)
                        }
                    }
                } catch {
                    issues.append(ProjectImportIssue(
                        sourceURL: input,
                        code: "project.directory_io",
                        message: "无法读取目录：\(error.localizedDescription)"
                    ))
                }
            } else if seen.insert(input.path).inserted {
                sources.append(input)
            }
        }
        return SourceExpansion(sources: sources, issues: issues)
    }

    private func readSafeSource(_ source: URL) throws -> SafeSourceSnapshot {
        guard isAssemblyURL(source) else {
            throw ImportFailure(code: "project.invalid_extension", message: "只能导入 .s 或 .S 文件。")
        }

        let descriptor = source.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw ImportFailure(code: "project.unsafe_link", message: "拒绝导入符号链接或硬链接。")
            }
            if errno == ENOENT {
                throw ImportFailure(code: "project.source_missing", message: "找不到待导入的源码。")
            }
            throw ImportFailure(
                code: "project.source_io",
                message: "无法安全打开源码：\(String(cString: strerror(errno)))"
            )
        }
        defer { Darwin.close(descriptor) }

        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ImportFailure(
                code: "project.source_io",
                message: "无法检查源码：\(String(cString: strerror(errno)))"
            )
        }
        let kind = metadata.st_mode & mode_t(S_IFMT)
        if metadata.st_nlink != 1 {
            throw ImportFailure(code: "project.unsafe_link", message: "拒绝导入符号链接或硬链接。")
        }
        guard kind == mode_t(S_IFREG) else {
            throw ImportFailure(code: "project.not_regular_file", message: "待导入路径不是普通文件。")
        }
        guard metadata.st_size >= 0, metadata.st_size <= off_t(maximumFileBytes) else {
            throw ImportFailure(
                code: "project.source_too_large",
                message: "源码文件过大（上限 \(maximumFileBytes) 字节）。"
            )
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ImportFailure(
                    code: "project.source_io",
                    message: "无法读取源码：\(String(cString: strerror(errno)))"
                )
            }
            guard data.count + count <= maximumFileBytes else {
                throw ImportFailure(
                    code: "project.source_too_large",
                    message: "源码文件过大（上限 \(maximumFileBytes) 字节）。"
                )
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return SafeSourceSnapshot(
            data: data,
            device: metadata.st_dev,
            inode: metadata.st_ino
        )
    }

    private func removeOriginalIfUnchanged(
        _ source: URL,
        snapshot: SafeSourceSnapshot
    ) -> ProjectImportIssue? {
        do {
            try beforeOriginalRemoval(source)
        } catch {
            return ProjectImportIssue(
                sourceURL: source,
                code: "project.original_retained",
                message: "工程已创建，但无法删除原文件：\(error.localizedDescription)"
            )
        }
        if belongsToExistingProject(source) {
            return ProjectImportIssue(
                sourceURL: source,
                code: "project.original_became_configured",
                message: "工程已创建，但原文件在导入期间加入了另一个 YAGARTO 工程，因此没有删除。"
            )
        }

        let parent = source.deletingLastPathComponent()
        let quarantine = parent.appendingPathComponent(
            ".yagarto-import-original-\(UUID().uuidString.lowercased()).\(source.pathExtension)"
        )
        let moved = source.withUnsafeFileSystemRepresentation { sourcePath in
            quarantine.withUnsafeFileSystemRepresentation { quarantinePath in
                guard let sourcePath, let quarantinePath else { return Int32(-1) }
                return Darwin.renamex_np(sourcePath, quarantinePath, UInt32(RENAME_EXCL))
            }
        }
        guard moved == 0 else {
            return ProjectImportIssue(
                sourceURL: source,
                code: "project.original_changed",
                message: "工程已创建，但原文件在导入期间发生变化或已被移动，因此没有删除。"
            )
        }

        if belongsToExistingProject(source) {
            let restored = restoreQuarantinedSource(quarantine, to: source)
            return ProjectImportIssue(
                sourceURL: source,
                code: "project.original_became_configured",
                message: retainedMessage(
                    restored: restored,
                    quarantine: quarantine,
                    normal: "工程已创建，但原文件在导入期间加入了另一个 YAGARTO 工程，因此保留原文件。"
                )
            )
        }

        do {
            let current = try readSafeSource(quarantine)
            guard current.device == snapshot.device,
                  current.inode == snapshot.inode,
                  current.data == snapshot.data else {
                let restored = restoreQuarantinedSource(quarantine, to: source)
                return ProjectImportIssue(
                    sourceURL: source,
                    code: "project.original_changed",
                    message: retainedMessage(
                        restored: restored,
                        quarantine: quarantine,
                        normal: "工程已创建，但原文件在导入期间发生变化，因此保留原文件。"
                    )
                )
            }
        } catch {
            let restored = restoreQuarantinedSource(quarantine, to: source)
            return ProjectImportIssue(
                sourceURL: source,
                code: "project.original_changed",
                message: retainedMessage(
                    restored: restored,
                    quarantine: quarantine,
                    normal: "工程已创建，但无法重新核对原文件，因此保留原文件。"
                )
            )
        }


        if belongsToExistingProject(source) {
            let restored = restoreQuarantinedSource(quarantine, to: source)
            return ProjectImportIssue(
                sourceURL: source,
                code: "project.original_became_configured",
                message: retainedMessage(
                    restored: restored,
                    quarantine: quarantine,
                    normal: "工程已创建，但原文件在导入期间加入了另一个 YAGARTO 工程，因此保留原文件。"
                )
            )
        }

        let removed = quarantine.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.unlink(path)
        }
        guard removed == 0 else {
            let detail = String(cString: strerror(errno))
            let restored = restoreQuarantinedSource(quarantine, to: source)
            return ProjectImportIssue(
                sourceURL: source,
                code: "project.original_retained",
                message: retainedMessage(
                    restored: restored,
                    quarantine: quarantine,
                    normal: "工程已创建，但无法删除原文件：\(detail)"
                )
            )
        }
        return nil
    }

    private func restoreQuarantinedSource(_ quarantine: URL, to source: URL) -> Bool {
        quarantine.withUnsafeFileSystemRepresentation { quarantinePath in
            source.withUnsafeFileSystemRepresentation { sourcePath in
                guard let quarantinePath, let sourcePath else { return false }
                return Darwin.renamex_np(quarantinePath, sourcePath, UInt32(RENAME_EXCL)) == 0
            }
        }
    }

    private func retainedMessage(restored: Bool, quarantine: URL, normal: String) -> String {
        if restored { return normal }
        return "\(normal) 保留版本位于：\(quarantine.path)；请勿删除，确认后手动移回。"
    }

    private func detectedEntry(in source: String, sourceURL: URL, profile: ProfileID) throws -> String {
        let uncommented = removingComments(from: source)
        if usesDynamicEntryDefinition(uncommented, isPreprocessed: sourceURL.pathExtension == "S") {
            throw ImportFailure(
                code: "project.dynamic_entry_unsupported",
                message: "源码使用预处理、条件汇编或宏定义，无法在不改写源码的前提下可靠判断入口。"
            )
        }
        var globals: Set<String> = []
        var labels: Set<String> = []
        let symbolPattern = #"^[\p{L}_.$][\p{L}\p{M}\p{N}_.$]*$"#

        for line in uncommented.split(whereSeparator: \Character.isNewline).map(String.init) {
            if let range = line.range(
                of: #"^\s*\.(?:global|globl)\s+(.+?)\s*$"#,
                options: [.regularExpression, .caseInsensitive]
            ) {
                let directive = String(line[range])
                if let valueRange = directive.range(of: #"\s+"#, options: .regularExpression) {
                    let values = directive[valueRange.upperBound...]
                    for token in values.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
                        let symbol = String(token)
                        if symbol.range(of: symbolPattern, options: .regularExpression) != nil {
                            globals.insert(symbol)
                        }
                    }
                }
            }
            if let range = line.range(
                of: #"^\s*([\p{L}_.$][\p{L}\p{M}\p{N}_.$]*)\s*:"#,
                options: .regularExpression
            ) {
                let prefix = String(line[range])
                if let colon = prefix.firstIndex(of: ":") {
                    labels.insert(prefix[..<colon].trimmingCharacters(in: .whitespaces))
                }
            }
        }

        let definedGlobals = globals.intersection(labels)
        let preferred = defaultEntry(for: profile)
        if definedGlobals.contains(preferred) { return preferred }
        if profile == .arm7tdmi, definedGlobals.contains("main") { return "main" }
        if definedGlobals.count == 1, let only = definedGlobals.first { return only }
        if definedGlobals.isEmpty {
            throw ImportFailure(code: "project.entry_not_found", message: "没有找到已定义的全局入口符号。")
        }
        throw ImportFailure(code: "project.entry_ambiguous", message: "存在多个全局入口候选，无法可靠判断入口。")
    }

    private func usesDynamicEntryDefinition(_ source: String, isPreprocessed: Bool) -> Bool {
        let assemblerDynamicPattern = #"(?:^|;)\s*\.(?:if[\p{L}\p{N}_]*|else|elseif|endif|macro|endm|rept|endr|irp|irpc)\b"#
        return source.split(whereSeparator: \Character.isNewline).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if isPreprocessed, line.hasPrefix("#") { return true }
            return line.range(
                of: assemblerDynamicPattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    private func removingComments(from source: String) -> String {
        var result = ""
        var index = source.startIndex
        var insideBlock = false
        while index < source.endIndex {
            let next = source.index(after: index)
            let pair = next < source.endIndex ? String(source[index...next]) : ""
            if insideBlock {
                if pair == "*/" {
                    insideBlock = false
                    index = source.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            if pair == "/*" {
                insideBlock = true
                index = source.index(after: next)
                continue
            }
            if pair == "//" || source[index] == "@" {
                while index < source.endIndex, !source[index].isNewline {
                    index = source.index(after: index)
                }
                continue
            }
            result.append(source[index])
            index = next
        }
        return result
    }

    private func belongsToExistingProject(_ source: URL) -> Bool {
        var directory = source.deletingLastPathComponent().standardizedFileURL
        while true {
            if fileMetadata(directory.appendingPathComponent("yagarto.json")) != nil {
                return true
            }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent == directory { return false }
            directory = parent
        }
    }

    private func validateProjectName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasControl = name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        guard !name.isEmpty,
              trimmed == name,
              name != ".",
              name != "..",
              !name.hasPrefix("."),
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains(":"),
              !hasControl else {
            throw YagartoError.invalidProjectName(name)
        }
    }

    private func validatedDirectory(_ rawURL: URL) throws -> URL {
        let directory = rawURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        guard let metadata = fileMetadata(directory),
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw YagartoError.invalidProjectParent(directory.path)
        }
        return directory
    }

    private func createPrivateStagingDirectory(in parent: URL) throws -> URL {
        for _ in 0..<32 {
            let candidate = parent.appendingPathComponent(
                ".yagarto-project-staging-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            let result = candidate.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.mkdir(path, S_IRWXU)
            }
            if result == 0 { return candidate }
            if errno != EEXIST {
                throw YagartoError.projectCreationFailed(candidate.path, String(cString: strerror(errno)))
            }
        }
        throw YagartoError.projectCreationFailed(parent.path, "无法创建唯一的工程暂存目录。")
    }

    private func publishExclusively(staging: URL, destination: URL) throws {
        let result = staging.withUnsafeFileSystemRepresentation { stagingPath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let stagingPath, let destinationPath else { return Int32(-1) }
                return Darwin.renamex_np(stagingPath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw PublishFailure.destinationExists }
            throw YagartoError.projectCreationFailed(destination.path, String(cString: strerror(errno)))
        }
    }

    private func fileMetadata(_ url: URL) -> stat? {
        var metadata = Darwin.stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else { return nil }
        return metadata
    }

    private func isAssemblyURL(_ url: URL) -> Bool {
        url.pathExtension == "s" || url.pathExtension == "S"
    }

    private func defaultEntry(for profile: ProfileID) -> String {
        profile == .arm7tdmi ? "start" : "main"
    }

    private func template(for profile: ProfileID) -> String {
        let entry = defaultEntry(for: profile)
        let cpu = profile == .arm7tdmi ? "arm7tdmi" : "cortex-m4"
        let mode = profile == .arm7tdmi ? ".arm" : ".thumb"
        let section = profile == .arm7tdmi ? ".text.start" : ".text.main"
        let thumbDirective = profile == .arm7tdmi ? "" : ".thumb_func\n"
        return """
        /* SPDX-License-Identifier: GPL-3.0-or-later */

        .syntax unified
        .cpu \(cpu)
        \(mode)

        .section \(section), "ax", %progbits
        .align 2
        .global \(entry)
        \(thumbDirective).type \(entry), %function
        \(entry):
            nop

        .Lhalt:
            b       .Lhalt
        .size \(entry), . - \(entry)

        .section .note.GNU-stack, "", %progbits
        """ + "\n"
    }
}

private extension ProjectCreator {
    struct SourceExpansion {
        let sources: [URL]
        let issues: [ProjectImportIssue]
    }

    struct ImportResult {
        let created: CreatedProject
        let warning: ProjectImportIssue?
    }

    struct SafeSourceSnapshot {
        let data: Data
        let device: dev_t
        let inode: ino_t
    }

    struct ImportFailure: Error {
        let code: String
        let message: String
    }

    enum PublishFailure: Error {
        case destinationExists
    }
}
