// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum YagartoError: Error, Equatable, Sendable {
    case configurationNotFound(String)
    case corruptedConfiguration(String)
    case configurationIOFailed(String, String)
    case unsupportedSchemaVersion(Int)
    case emptySources
    case invalidSourceExtension(String)
    case absoluteSourcePath(String)
    case pathTraversal(String)
    case sourceEscapesProject(String)
    case outputSymlink(String)
    case duplicateSource(String)
    case invalidOutputName(String)
    case duplicateObjectName(String)
    case toolNotFound(String)
    case missingResource(String)
    case processIOFailed(String, String)
    case processLaunchFailed(String, String)
    case buildStepFailed(String, Int32, String)
    case cannotWriteOutput(String, String)
    case internalFailure(String)
}

extension YagartoError: LocalizedError {
    public var errorDescription: String? {
        guard let details else {
            return message
        }
        return "\(message)\n\(details)"
    }

    public var diagnosticCode: String {
        switch self {
        case .configurationNotFound:
            return "configuration.not_found"
        case .corruptedConfiguration:
            return "configuration.invalid_json"
        case .configurationIOFailed:
            return "configuration.io"
        case .unsupportedSchemaVersion:
            return "configuration.unsupported_schema"
        case .emptySources:
            return "configuration.empty_sources"
        case .invalidSourceExtension:
            return "configuration.invalid_source_extension"
        case .absoluteSourcePath:
            return "configuration.absolute_source"
        case .pathTraversal:
            return "configuration.path_traversal"
        case .sourceEscapesProject:
            return "configuration.source_escape"
        case .outputSymlink:
            return "configuration.output_symlink"
        case .duplicateSource:
            return "configuration.duplicate_source"
        case .invalidOutputName:
            return "configuration.invalid_output_name"
        case .duplicateObjectName:
            return "build.duplicate_object"
        case .toolNotFound:
            return "tool.not_found"
        case .missingResource:
            return "resource.missing"
        case .processIOFailed:
            return "process.io"
        case .processLaunchFailed:
            return "process.launch_failed"
        case .buildStepFailed:
            return "build.step_failed"
        case .cannotWriteOutput:
            return "build.output_io"
        case .internalFailure:
            return "internal.failure"
        }
    }

    public var message: String {
        switch self {
        case .configurationNotFound:
            return "未找到 yagarto.json。请先运行 yagarto-mac init。"
        case .corruptedConfiguration:
            return "yagarto.json 格式无效。请修正 JSON 后重试。"
        case .configurationIOFailed:
            return "无法读写配置文件。请检查路径和目录权限后重试。"
        case .unsupportedSchemaVersion(let version):
            return "不支持配置版本 \(version)；当前仅支持 schemaVersion 1。"
        case .emptySources:
            return "sources 不能为空；请至少添加一个 .s 或 .S 文件。"
        case .invalidSourceExtension(let source):
            return "源文件“\(source)”必须使用 .s 或 .S 扩展名。"
        case .absoluteSourcePath(let source):
            return "源文件路径“\(source)”不能是绝对路径；请使用项目内相对路径。"
        case .pathTraversal(let path):
            return "路径“\(path)”不能包含 ..；请使用项目目录内的路径。"
        case .sourceEscapesProject(let source):
            return "源文件“\(source)”解析后位于项目目录之外；请移除越界符号链接。"
        case .outputSymlink(let path):
            return "输出路径“\(path)”是符号链接；为避免写出项目目录，构建已停止。"
        case .duplicateSource(let source):
            return "源文件“\(source)”与另一个输入指向同一文件；请移除重复项。"
        case .invalidOutputName(let outputName):
            return "输出名“\(outputName)”必须是单个相对文件名，不能包含目录或路径穿越。"
        case .duplicateObjectName(let objectName):
            return "多个源文件会生成同名目标文件“\(objectName)”；请重命名其中一个源文件。"
        case .toolNotFound(let tool):
            return "未找到工具 \(tool)。请安装 Arm GNU Toolchain，或提供该工具的显式路径。"
        case .missingResource(let name):
            return "缺少内置资源“\(name)”；请重新安装 yagarto-mac。"
        case .processIOFailed:
            return "无法创建或读取进程捕获文件。请检查临时目录权限和可用空间。"
        case .processLaunchFailed(let executable, _):
            return "无法启动“\(executable)”。请检查工具路径和执行权限。"
        case .buildStepFailed(let executable, let status, _):
            return "构建步骤“\(executable)”失败（退出状态 \(status)）。"
        case .cannotWriteOutput:
            return "无法写入构建输出。请检查目录权限和可用空间。"
        case .internalFailure:
            return "发生未预期的内部错误。请检查参数后重试。"
        }
    }

    public var details: String? {
        switch self {
        case .configurationNotFound(let path):
            return "路径：\(path)"
        case .corruptedConfiguration(let detail):
            return detail
        case .configurationIOFailed(let path, let detail):
            return "路径：\(path)；\(detail)"
        case .processIOFailed(let path, let detail):
            return "路径：\(path)；\(detail)"
        case .processLaunchFailed(_, let detail):
            return detail
        case .buildStepFailed(_, _, let detail):
            return detail.isEmpty ? nil : detail
        case .cannotWriteOutput(let path, let detail):
            return "路径：\(path)；\(detail)"
        case .internalFailure(let detail):
            return detail
        default:
            return nil
        }
    }

    public var exitCode: YagartoExitCode {
        switch self {
        case .toolNotFound:
            return .missingTool
        case .missingResource:
            return .unsupported
        case .processIOFailed, .processLaunchFailed, .buildStepFailed, .cannotWriteOutput:
            return .buildFailure
        case .internalFailure:
            return .unsupported
        default:
            return .configuration
        }
    }
}
