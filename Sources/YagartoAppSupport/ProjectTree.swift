// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct ProjectTreeNode: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case folder
        case source
    }

    public let kind: Kind
    public let name: String
    public let relativePath: String
    public let isDirty: Bool
    public let children: [ProjectTreeNode]

    public var outlineChildren: [ProjectTreeNode]? {
        children.isEmpty ? nil : children
    }

    public var id: String {
        switch kind {
        case .folder: return "folder:\(relativePath)"
        case .source: return "source:\(relativePath)"
        }
    }

    public static func build(from buffers: [WorkspaceSourceBuffer]) -> [ProjectTreeNode] {
        var roots: [BuilderNode] = []
        for buffer in buffers {
            let components = buffer.relativePath
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !components.isEmpty else { continue }
            insert(
                components: ArraySlice(components),
                fullRelativePath: buffer.relativePath,
                isDirty: buffer.isDirty,
                into: &roots,
                parentPath: ""
            )
        }
        return roots.map(\.value)
    }

    private static func insert(
        components: ArraySlice<String>,
        fullRelativePath: String,
        isDirty: Bool,
        into nodes: inout [BuilderNode],
        parentPath: String
    ) {
        guard let component = components.first else { return }
        if components.count == 1 {
            nodes.append(BuilderNode(
                kind: .source,
                name: component,
                relativePath: fullRelativePath,
                isDirty: isDirty
            ))
            return
        }

        let folderPath = parentPath.isEmpty ? component : "\(parentPath)/\(component)"
        let index: Int
        if let existing = nodes.firstIndex(where: {
            $0.kind == .folder && $0.relativePath == folderPath
        }) {
            index = existing
        } else {
            nodes.append(BuilderNode(
                kind: .folder,
                name: component,
                relativePath: folderPath,
                isDirty: false
            ))
            index = nodes.count - 1
        }
        insert(
            components: components.dropFirst(),
            fullRelativePath: fullRelativePath,
            isDirty: isDirty,
            into: &nodes[index].children,
            parentPath: folderPath
        )
    }
}

private struct BuilderNode {
    let kind: ProjectTreeNode.Kind
    let name: String
    let relativePath: String
    let isDirty: Bool
    var children: [BuilderNode] = []

    var value: ProjectTreeNode {
        ProjectTreeNode(
            kind: kind,
            name: name,
            relativePath: relativePath,
            isDirty: isDirty || children.contains(where: { $0.value.isDirty }),
            children: children.map(\.value)
        )
    }
}
