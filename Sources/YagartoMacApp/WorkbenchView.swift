// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import YagartoAppSupport
import YagartoCore

@MainActor
struct WorkbenchView: View {
    @Bindable var model: AppViewModel
    let openExample: (() -> Void)?

    @State private var memoryAddress = "$sp"
    @State private var memoryLength = "64"

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            Divider()
            if let document = model.document {
                workbench(document)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(WindowCloseGuard(model: model).frame(width: 0, height: 0))
        .toolbar { toolbar }
    }

    private var statusStrip: some View {
        HStack(spacing: 14) {
            Text(stateLabel)
                .font(.caption.weight(.semibold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stateLabel)
                .accessibilityIdentifier("debugger-state")
            if let current = model.currentExecutionLine {
                Label("当前执行第 \(current) 行", systemImage: "arrow.right")
                    .font(.caption)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("当前执行第 \(current) 行")
                    .accessibilityIdentifier("current-line-status")
            }
            if let range = model.selectedRange, let document = model.document {
                let line = SourceLineMap(document.text).lineNumber(atUTF16Offset: range.location)
                Text("已定位到第 \(line) 行")
                    .font(.caption)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("已定位到第 \(line) 行")
                    .accessibilityIdentifier("source-location-status")
            }
            Spacer()
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.red)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(error)
                    .accessibilityIdentifier("operation-error")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("打开 ARM 汇编工程")
                .font(.title3.weight(.semibold))
            Text("选择包含 yagarto.json 的目录，或选择该目录内的 .s / .S 文件。")
                .foregroundStyle(.secondary)
            HStack {
                Button("打开工程…") { OpenProjectAction.choose(for: model) }
                    .keyboardShortcut("o", modifiers: .command)
                    .accessibilityIdentifier("empty-open-project")
                if let openExample {
                    Button("打开示例", action: openExample)
                        .accessibilityIdentifier("open-example")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty-state")
    }

    private func workbench(_ document: WorkspaceDocument) -> some View {
        VSplitView {
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text(document.sourceURL.lastPathComponent)
                            .font(.caption.weight(.semibold))
                        if document.isDirty { Text("已修改").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(.bar)
                    AssemblyEditorView(
                        text: document.text,
                        breakpoints: model.breakpoints.lines,
                        currentLine: model.currentExecutionLine,
                        selectionRequest: model.selectedRange,
                        isEditable: model.isEnabled(.edit),
                        onTextChange: { model.edit($0) },
                        onToggleBreakpoint: { line in Task { await model.toggleBreakpoint(line: line) } }
                    )
                }
                .frame(minWidth: 520)

                registerPane(profile: document.configuration.profile)
                    .frame(minWidth: 230, idealWidth: 280, maxWidth: 360)
            }
            .frame(minHeight: 350)

            detailsPane
                .frame(minHeight: 170, idealHeight: 240)
        }
    }

    private func registerPane(profile: ProfileID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("寄存器")
                .font(.headline)
                .padding(.horizontal, 10)
                .frame(height: 34)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows(for: profile)) { row in
                        HStack(spacing: 8) {
                            Text(row.name)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .frame(width: 70, alignment: .leading)
                            Text(row.value)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .accessibilityIdentifier("register-\(row.name.lowercased())")
                                .accessibilityValue(row.accessibilityValue)
                            Spacer()
                            if row.hasChanged {
                                Label("已变化", systemImage: "arrow.up.right")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 30)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("register-row-\(row.name.lowercased())")
                        Divider()
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var detailsPane: some View {
        TabView {
            consolePane.tabItem { Label("控制台", systemImage: "terminal") }
            stackPane.tabItem { Label("栈", systemImage: "square.stack.3d.up") }
            memoryPane.tabItem { Label("内存", systemImage: "memorychip") }
            disassemblyPane.tabItem { Label("反汇编", systemImage: "list.bullet.rectangle") }
        }
        .padding(6)
    }

    private var consolePane: some View {
        HSplitView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.console.entries.enumerated()), id: \.offset) { _, entry in
                        Text("[\(entry.channel.rawValue)] \(entry.text)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if model.console.droppedCount > 0 {
                        Text("已省略 \(model.console.droppedCount) 条旧控制台消息")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("构建诊断").font(.caption.weight(.semibold))
                ScrollView {
                    ForEach(model.buildDiagnostics) { diagnostic in
                        Button {
                            model.selectDiagnostic(diagnostic)
                        } label: {
                            Label(
                                "\(diagnostic.line.map { "第 \($0) 行：" } ?? "")\(diagnostic.message)",
                                systemImage: diagnostic.severity == .error ? "xmark.octagon" : "exclamationmark.triangle"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("build-diagnostic-\(diagnostic.line ?? 0)")
                    }
                }
            }
            .frame(minWidth: 280)
        }
    }

    private var stackPane: some View {
        List(Array((model.snapshot?.stack ?? []).enumerated()), id: \.offset) { index, frame in
            HStack {
                Text("#\(index)").font(.system(.body, design: .monospaced))
                Text(frame.function ?? "未知函数")
                Spacer()
                Text("\(frame.file ?? "—"):\(frame.line?.raw ?? "—")").foregroundStyle(.secondary)
            }
        }
    }

    private var memoryPane: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("地址，如 0x20001000 或 $sp", text: $memoryAddress)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("memory-address")
                TextField("长度", text: $memoryLength)
                    .frame(width: 80)
                    .accessibilityIdentifier("memory-length")
                Button("读取") { Task { await model.readMemory(address: memoryAddress, length: memoryLength) } }
                    .disabled(model.state != .stopped)
                    .accessibilityIdentifier("memory-read")
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(Array(model.memory.enumerated()), id: \.offset) { _, block in
                        Text("\(block.begin.raw): \(block.contents)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var disassemblyPane: some View {
        List(Array((model.snapshot?.disassembly ?? []).enumerated()), id: \.offset) { _, instruction in
            HStack {
                Text(instruction.address.raw).frame(width: 110, alignment: .leading)
                Text(instruction.instruction)
            }
            .font(.system(.body, design: .monospaced))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("目标 profile", selection: Binding(
                get: { model.document?.configuration.profile ?? .arm7tdmi },
                set: { model.changeProfile(to: $0) }
            )) {
                Text("ARM7TDMI").tag(ProfileID.arm7tdmi)
                Text("Cortex-M4").tag(ProfileID.cortexM4)
                Text("STM32F4 Discovery").tag(ProfileID.stm32f4Discovery)
            }
            .frame(width: 175)
            .disabled(!model.isEnabled(.changeProfile))
            .accessibilityIdentifier("profile-picker")
        }
        ToolbarItemGroup {
            toolbarButton("folder", "打开工程", "选择 .s/.S 文件或工程目录", "toolbar-open", enabled: model.isEnabled(.open)) {
                OpenProjectAction.choose(for: model)
            }
            toolbarButton("square.and.arrow.down", "保存", "保存当前源码与 profile", "toolbar-save", enabled: model.isEnabled(.save)) {
                Task { await model.save() }
            }
            toolbarButton("hammer", "构建", "自动保存后构建工程", "toolbar-build", enabled: model.isEnabled(.build)) {
                Task { await model.build() }
            }
            toolbarButton("play", "运行", "运行当前 ELF", "toolbar-run", enabled: model.isEnabled(.run)) {
                Task { await model.start(.run) }
            }
            toolbarButton("ladybug", "启动调试", "在入口停止并加载寄存器", "toolbar-debug", enabled: model.isEnabled(.debug)) {
                Task { await model.start(.debug) }
            }
            toolbarButton("pause", "暂停", "暂停正在运行的程序", "toolbar-pause", enabled: model.isEnabled(.pause)) {
                Task { await model.pause() }
            }
            toolbarButton("arrow.right.to.line", "单步指令", "执行一条机器指令", "toolbar-step-instruction", enabled: model.isEnabled(.stepInstruction)) {
                Task { await model.stepInstruction() }
            }
            toolbarButton("arrow.turn.down.right", "单步越过", "越过当前源码语句", "toolbar-step-over", enabled: model.isEnabled(.stepOver)) {
                Task { await model.stepOver() }
            }
            toolbarButton("forward", "继续", "继续运行程序", "toolbar-continue", enabled: model.isEnabled(.continue)) {
                Task { await model.resume() }
            }
            toolbarButton("stop", "停止", "有界停止调试器和后端", "toolbar-stop", enabled: model.isEnabled(.stop)) {
                Task { await model.stop() }
            }
        }
    }

    private func toolbarButton(
        _ systemImage: String,
        _ label: String,
        _ hint: String,
        _ identifier: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }

    private func rows(for profile: ProfileID) -> [RegisterRow] {
        guard model.registerRows.isEmpty else { return model.registerRows }
        return RegisterPresentation.names(for: profile).map {
            RegisterRow(name: $0, value: "—", hasChanged: false)
        }
    }

    private var stateLabel: String {
        switch model.state {
        case .idle: return "未构建"
        case .building: return "构建中"
        case .ready: return "就绪"
        case .launching: return "正在启动"
        case .stopped: return "已暂停"
        case .running: return "运行中"
        case .terminating: return "正在停止"
        }
    }
}

@MainActor
enum OpenProjectAction {
    static func choose(for model: AppViewModel) {
        let panel = NSOpenPanel()
        panel.title = "打开 YAGARTO 工程或汇编源码"
        panel.message = "选择包含 yagarto.json 的工程目录，或 .s / .S 源码文件。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.open(url) }
    }
}

@MainActor
struct WorkbenchCommands: Commands {
    let model: AppViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开…") { OpenProjectAction.choose(for: model) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!model.isEnabled(.open))
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存") { Task { await model.save() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.isEnabled(.save))
        }
        CommandMenu("调试") {
            Button("构建") { Task { await model.build() } }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!model.isEnabled(.build))
            Button("运行") { Task { await model.start(.run) } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.isEnabled(.run))
            Button("启动调试") { Task { await model.start(.debug) } }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!model.isEnabled(.debug))
            Divider()
            Button("暂停") { Task { await model.pause() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.isEnabled(.pause))
            Button("单步指令") { Task { await model.stepInstruction() } }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!model.isEnabled(.stepInstruction))
            Button("单步越过") { Task { await model.stepOver() } }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.isEnabled(.stepOver))
            Button("继续") { Task { await model.resume() } }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!model.isEnabled(.continue))
            Button("停止") { Task { await model.stop() } }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!model.isEnabled(.stop))
        }
    }
}
