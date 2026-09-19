// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import YagartoAppSupport

@MainActor
enum ProjectSourceActions {
    static func chooseSources(startingAt directory: URL) -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "添加现有汇编文件"
        panel.message = "所选 .s/.S 文件会复制到当前工程，原文件保持不变。"
        panel.directoryURL = directory
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    static func confirmTrash(
        source: WorkspaceSourceBuffer,
        isLastSource: Bool
    ) -> DirtySourceTrashPolicy? {
        if isLastSource {
            let alert = NSAlert()
            alert.messageText = "不能移到废纸篓"
            alert.informativeText = "工程必须至少保留一个源码。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return nil
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "将“\(source.relativePath)”移到废纸篓？"
        if source.isDirty {
            alert.informativeText = "此文件包含未保存修改。你可以先保存该文件的最新内容，或放弃修改后将上次保存版本移到废纸篓。"
            alert.addButton(withTitle: "保存后移到废纸篓")
            alert.addButton(withTitle: "放弃修改并移到废纸篓")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .saveLatest
            case .alertSecondButtonReturn: return .discardChanges
            default: return nil
            }
        }

        alert.informativeText = "文件会从工程配置中移除，并进入 macOS 废纸篓。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? .discardChanges : nil
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copyRelativePath(_ relativePath: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(relativePath, forType: .string)
    }
}
