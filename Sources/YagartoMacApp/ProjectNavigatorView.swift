// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import YagartoAppSupport

@MainActor
struct ProjectNavigatorView: View {
    @Bindable var model: AppViewModel
    @Binding var renameRequestedPath: String?
    let openProject: () -> Void
    let openRecentProject: (RecentProject) -> Void
    let clearRecentProjects: () -> Void
    let newSource: () -> Void
    let addExistingSources: () -> Void
    let renameSource: (String, String) async -> Bool
    let trashSource: (String) -> Void

    @State private var renamingPath: String?
    @State private var renameDraft = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            projectHeader
            Divider()
            ScrollView {
                OutlineGroup(model.projectTree, children: \.outlineChildren) { node in
                    treeRow(node)
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("project-tree")
            Divider()
            actionBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-sources")
        .onChange(of: renameRequestedPath) { _, requested in
            guard let requested else { return }
            beginRename(requested)
        }
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Menu {
                if !model.recentProjects.isEmpty {
                    Section("最近工程") {
                        ForEach(model.recentProjects) { project in
                            Button(project.displayName) {
                                openRecentProject(project)
                            }
                        }
                    }
                    Divider()
                }
                Button("打开其他工程…", action: openProject)
                Button("在 Finder 中显示工程") {
                    guard let directory = model.document?.projectDirectory else { return }
                    ProjectSourceActions.reveal(directory)
                }
                if !model.recentProjects.isEmpty {
                    Divider()
                    Button("清除最近工程", action: clearRecentProjects)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(model.document?.projectDirectory.lastPathComponent ?? "工程")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier("project-menu")
            .accessibilityLabel("当前工程，\(model.document?.projectDirectory.lastPathComponent ?? "未打开")")
            .accessibilityHint("打开最近工程、其他工程或在 Finder 中显示")

            Text(projectDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("project-detail")
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var projectDetail: String {
        guard let document = model.document else { return "" }
        return "\(document.configuration.profile.rawValue) · \(document.projectDirectory.path)"
    }

    @ViewBuilder
    private func treeRow(_ node: ProjectTreeNode) -> some View {
        switch node.kind {
        case .folder:
            Button {
                model.selectProjectDirectory(node.relativePath)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                    Text(node.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if node.isDirty {
                        Text("已修改")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                model.selectedProjectDirectoryRelativePath == node.relativePath
                    ? Color.accentColor.opacity(0.10) : Color.clear
            )
            .disabled(!model.canManageProjectSources)
            .accessibilityIdentifier("directory-row-\(node.relativePath)")
            .accessibilityLabel("目录 \(node.relativePath)\(node.isDirty ? "，包含已修改文件" : "")")
            .accessibilityHint("选择为新源码的目标目录")

        case .source:
            sourceRow(node)
        }
    }

    @ViewBuilder
    private func sourceRow(_ node: ProjectTreeNode) -> some View {
        let isActive = node.relativePath == model.document?.activeSourceRelativePath
        if renamingPath == node.relativePath {
            TextField("源码文件名", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .focused($renameFieldFocused)
                .frame(minHeight: 44)
                .onSubmit { submitRename(node.relativePath) }
                .onExitCommand { cancelRename() }
                .accessibilityIdentifier("rename-source-field-\(node.relativePath)")
        } else {
            Button {
                Task { await model.selectSource(node.relativePath) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isActive ? "doc.text.fill" : "doc.text")
                        .frame(width: 16)
                    Text(node.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if node.isDirty {
                        Text("已修改")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            .disabled(!model.canSelectSource)
            .accessibilityIdentifier("source-row-\(node.relativePath)")
            .accessibilityLabel(sourceAccessibilityLabel(node, isActive: isActive))
            .accessibilityHint(isActive ? "当前正在显示的源码" : "切换到此源码")
            .contextMenu {
                Button("重命名…") { beginRename(node.relativePath) }
                    .disabled(!model.canManageProjectSources)
                Button("在 Finder 中显示") {
                    guard let directory = model.document?.projectDirectory else { return }
                    ProjectSourceActions.reveal(directory.appendingPathComponent(node.relativePath))
                }
                Button("复制相对路径") {
                    ProjectSourceActions.copyRelativePath(node.relativePath)
                }
                Divider()
                Button("移到废纸篓", role: .destructive) {
                    trashSource(node.relativePath)
                }
                .disabled(!model.canManageProjectSources || model.document?.sourceBuffers.count == 1)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 4) {
            Menu {
                Button("新建汇编文件…", action: newSource)
                    .accessibilityIdentifier("new-source")
                Button("添加现有汇编文件…", action: addExistingSources)
                    .accessibilityIdentifier("add-existing-sources")
            } label: {
                Image(systemName: "plus")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .disabled(!model.canManageProjectSources)
            .accessibilityIdentifier("source-add-menu")
            .accessibilityLabel("添加工程源码")
            .accessibilityHint("新建汇编文件或复制现有汇编文件到工程")

            Spacer()

            Button {
                guard let directory = model.document?.projectDirectory else { return }
                ProjectSourceActions.reveal(directory)
            } label: {
                Image(systemName: "arrow.forward.circle")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("在 Finder 中显示工程")
        }
        .padding(.horizontal, 4)
    }

    private func sourceAccessibilityLabel(_ node: ProjectTreeNode, isActive: Bool) -> String {
        var parts = [node.relativePath]
        if isActive { parts.append("当前文件") }
        if node.isDirty { parts.append("已修改") }
        return parts.joined(separator: "，")
    }

    private func beginRename(_ relativePath: String) {
        guard model.canManageProjectSources else { return }
        renamingPath = relativePath
        renameRequestedPath = relativePath
        renameDraft = (relativePath as NSString).lastPathComponent
        Task { @MainActor in
            await Task.yield()
            renameFieldFocused = true
        }
    }

    private func submitRename(_ relativePath: String) {
        let candidate = renameDraft
        Task { @MainActor in
            if await renameSource(relativePath, candidate) {
                cancelRename()
            }
        }
    }

    private func cancelRename() {
        renamingPath = nil
        renameRequestedPath = nil
        renameDraft = ""
        renameFieldFocused = false
    }
}
