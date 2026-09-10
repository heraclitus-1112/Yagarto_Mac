// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum YagartoError: Error, Equatable, Sendable {
    case configurationNotFound(String)
    case corruptedConfiguration(String)
    case unsupportedSchemaVersion(Int)
    case emptySources
    case invalidSourceExtension(String)
    case absoluteSourcePath(String)
    case pathTraversal(String)
    case invalidOutputName(String)
    case duplicateObjectName(String)
    case toolNotFound(String)
    case missingResource(String)
    case processLaunchFailed(String, String)
    case buildStepFailed(String, Int32, String)
    case cannotWriteOutput(String, String)
}

extension YagartoError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .configurationNotFound(let path):
            return "未找到配置文件：\(path)。请先运行 yagarto-mac init。"
        case .corruptedConfiguration(let detail):
            return "无法读取 yagarto.json：\(detail)。请修正 JSON 后重试。"
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
        case .invalidOutputName(let outputName):
            return "输出名“\(outputName)”必须是单个相对文件名，不能包含目录或路径穿越。"
        case .duplicateObjectName(let objectName):
            return "多个源文件会生成同名目标文件“\(objectName)”；请重命名其中一个源文件。"
        case .toolNotFound(let tool):
            return "未找到工具 \(tool)。请安装 Arm GNU Toolchain，或提供该工具的显式路径。"
        case .missingResource(let name):
            return "缺少内置资源“\(name)”；请重新安装 yagarto-mac。"
        case .processLaunchFailed(let executable, let detail):
            return "无法启动“\(executable)”：\(detail)"
        case .buildStepFailed(let executable, let status, let detail):
            let suffix = detail.isEmpty ? "请检查输入文件和工具链参数。" : detail
            return "构建步骤“\(executable)”失败（退出状态 \(status)）：\(suffix)"
        case .cannotWriteOutput(let path, let detail):
            return "无法写入输出“\(path)”：\(detail)"
        }
    }

    public var exitCode: YagartoExitCode {
        switch self {
        case .toolNotFound:
            return .missingTool
        case .missingResource:
            return .unsupported
        case .processLaunchFailed, .buildStepFailed, .cannotWriteOutput:
            return .buildFailure
        default:
            return .configuration
        }
    }
}
