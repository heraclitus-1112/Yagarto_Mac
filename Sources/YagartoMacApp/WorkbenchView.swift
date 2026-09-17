// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import YagartoAppSupport
import YagartoCore

@MainActor
struct WorkbenchView: View {
    @Bindable var model: AppViewModel
    let openExample: (() -> Void)?
    let defaultProjectParent: URL?
    let defaultProjectProfile: ProfileID?
    let importInputsOverride: [URL]?

    @State private var memoryWindowControl = MemoryWindowControlState()
    @State private var memoryAddressTask: Task<Void, Never>?
    @State private var presentedProjectSheet: ProjectSheet?
    @AppStorage("lastProjectParentPath") private var lastProjectParentPath = ""
    @AppStorage("lastProjectProfile") private var lastProjectProfile = ProfileID.arm7tdmi.rawValue

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
        .sheet(item: $presentedProjectSheet) { sheet in
            projectSheet(sheet)
        }
        .focusedSceneValue(\.newYagartoProjectAction, model.isEnabled(.newProject) ? {
            requestNewProject()
        } : nil)
        .focusedSceneValue(\.importYagartoProjectsAction, model.isEnabled(.importProjects) ? {
            requestProjectImport()
        } : nil)
        .onChange(of: model.document?.configuration.profile) { _, profile in
            if defaultProjectProfile == nil, let profile {
                lastProjectProfile = profile.rawValue
            }
            resetMemoryWindow()
        }
        .onChange(of: model.documentInstanceID) { _, _ in
            resetMemoryWindow()
        }
        .onChange(of: model.state) { oldState, newState in
            if newState == .ready, oldState == .launching || oldState == .terminating {
                resetMemoryWindow()
            }
        }
    }

    private var statusStrip: some View {
        AccessibleStatusStrip(
            stateText: stateLabel,
            currentLineText: model.currentExecutionLine.map { "→ 当前执行第 \($0) 行" },
            sourceLocationText: sourceLocationText,
            operationErrorText: model.errorMessage.map { "⚠︎ \($0)" }
        )
        .frame(height: StatusStackView.preferredHeight)
        .background(.bar)
    }

    private var sourceLocationText: String? {
        guard let range = model.selectedRange, let document = model.document else { return nil }
        let line = SourceLineMap(document.text).lineNumber(atUTF16Offset: range.location)
        return "已定位到第 \(line) 行"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("新建或打开 ARM 汇编工程")
                .font(.title3.weight(.semibold))
            Text("自动创建工程，或打开包含 yagarto.json 的目录。")
                .foregroundStyle(.secondary)
            HStack {
                Button("新建工程…") { requestNewProject() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.isEnabled(.newProject))
                    .accessibilityIdentifier("empty-new-project")
                Button("导入现有源码…") { requestProjectImport() }
                    .disabled(!model.isEnabled(.importProjects))
                    .accessibilityIdentifier("empty-import-projects")
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

    @ViewBuilder
    private func projectSheet(_ sheet: ProjectSheet) -> some View {
        switch sheet.content {
        case .newProject:
            NewProjectSheet(
                model: model,
                parentDirectory: rememberedParentDirectory,
                profile: rememberedProfile
            ) { created in
                if let created {
                    lastProjectParentPath = created.projectDirectory.deletingLastPathComponent().path
                    lastProjectProfile = created.configuration.profile.rawValue
                    presentedProjectSheet = nil
                }
            } onCancel: {
                presentedProjectSheet = nil
            }
        case .importProjects(let inputs):
            ImportProjectsSheet(model: model, inputs: inputs, profile: rememberedProfile) { report in
                lastProjectProfile = report.profile.rawValue
                presentedProjectSheet = nil
                Task { @MainActor in
                    await Task.yield()
                    presentedProjectSheet = ProjectSheet(content: .importSummary(report))
                }
            } onCancel: {
                presentedProjectSheet = nil
            }
        case .importSummary(let report):
            ImportSummarySheet(report: report) {
                presentedProjectSheet = nil
            }
        }
    }

    private var rememberedParentDirectory: URL {
        if let defaultProjectParent { return defaultProjectParent }
        if !lastProjectParentPath.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: lastProjectParentPath, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: lastProjectParentPath, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private var rememberedProfile: ProfileID {
        defaultProjectProfile ?? ProjectProfilePreference.selected(
            lastRawValue: lastProjectProfile,
            current: model.document?.configuration.profile
        )
    }

    private func requestNewProject() {
        guard model.isEnabled(.newProject) else { return }
        Task { @MainActor in
            guard await ProjectReplacementApproval.confirm(for: model) else { return }
            presentedProjectSheet = ProjectSheet(content: .newProject)
        }
    }

    private func requestProjectImport() {
        guard model.isEnabled(.importProjects) else { return }
        let inputs = importInputsOverride ?? ImportProjectAction.choose()
        guard let inputs, !inputs.isEmpty else { return }
        presentedProjectSheet = ProjectSheet(content: .importProjects(inputs))
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
            HStack(spacing: 8) {
                Text("Address")
                    .fixedSize()
                TextField(
                    MemoryWindowLayout.defaultAddressText,
                    text: Binding(
                        get: { memoryWindowControl.editableAddressText },
                        set: { memoryWindowControl.edit($0) }
                    )
                )
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 130, idealWidth: 160, maxWidth: 220)
                    .onSubmit { submitMemoryAddress(memoryWindowControl.editableAddressText) }
                    .accessibilityLabel("内存起始地址")
                    .accessibilityHint("输入十六进制地址后按回车提交")
                    .accessibilityIdentifier("memory-address")
                Stepper(
                    "16 bytes",
                    onIncrement: { stepMemoryAddress(byRows: 1) },
                    onDecrement: { stepMemoryAddress(byRows: -1) }
                )
                .fixedSize()
                .accessibilityLabel("内存地址步进，每次 16 字节")
                .accessibilityHint("增加或减少一行内存地址")
                .accessibilityIdentifier("memory-address-stepper")
                Spacer(minLength: 12)
                Text("Target is LITTLE endian")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityIdentifier("memory-endianness")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MemoryHexTable(blocks: model.memory, baseAddress: memoryWindowControl.displayedBaseAddress)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func submitMemoryAddress(_ candidate: String) {
        do {
            let submission = try memoryWindowControl.beginSubmission(candidate)
            startMemoryAddressSubmission(submission)
        } catch {
            rejectMemoryAddressSubmission(error)
        }
    }

    private func startMemoryAddressSubmission(_ submission: MemoryWindowControlState.Submission) {
        memoryAddressTask?.cancel()
        let candidate = submission.normalizedAddress
        memoryAddressTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let normalized = await model.setMemoryWindowAddress(candidate)
            guard !Task.isCancelled else { return }
            if let normalized {
                memoryWindowControl.completeSuccess(token: submission.token, normalized: normalized)
            } else {
                memoryWindowControl.completeFailure(token: submission.token)
            }
            memoryAddressTask = nil
        }
    }

    private func stepMemoryAddress(byRows rowCount: Int) {
        do {
            let submission = try memoryWindowControl.step(byRows: rowCount)
            startMemoryAddressSubmission(submission)
        } catch {
            rejectMemoryAddressSubmission(error)
        }
    }

    private func rejectMemoryAddressSubmission(_ error: Error) {
        memoryWindowControl.rollbackDisplayedToConfirmed()
        memoryAddressTask?.cancel()
        memoryAddressTask = nil
        model.invalidateMemoryWindowAddressOperation()
        model.reportMemoryWindowError(error)
    }

    private func resetMemoryWindow() {
        memoryAddressTask?.cancel()
        memoryAddressTask = nil
        memoryWindowControl.reset()
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
        if model.isProjectOperationInProgress { return "正在整理工程" }
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
        Task { @MainActor in
            guard await ProjectReplacementApproval.confirm(for: model) else { return }
            let panel = NSOpenPanel()
            panel.title = "打开 YAGARTO 工程或汇编源码"
            panel.message = "选择包含 yagarto.json 的工程目录，或 .s / .S 源码文件。"
            panel.canChooseDirectories = true
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = []
            guard panel.runModal() == .OK, let url = panel.url else { return }
            await model.open(url)
        }
    }
}

@MainActor
enum ImportProjectAction {
    static func choose() -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "导入独立 ARM 汇编源码"
        panel.message = "可选择多个 .s/.S 文件，或选择一个只扫描当前层的目录。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }
}

@MainActor
enum ProjectReplacementApproval {
    static func confirm(for model: AppViewModel) async -> Bool {
        guard model.document?.isDirty == true else { return true }
        let alert = NSAlert()
        alert.messageText = "源码尚未保存"
        alert.informativeText = "切换工程前保存修改吗？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            await model.save()
            return model.document?.isDirty != true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

@MainActor
struct WorkbenchCommands: Commands {
    let model: AppViewModel
    @FocusedValue(\.newYagartoProjectAction) private var newProjectAction
    @FocusedValue(\.importYagartoProjectsAction) private var importProjectsAction

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建工程…") { newProjectAction?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newProjectAction == nil || !model.isEnabled(.newProject))
            Button("导入现有源码…") { importProjectsAction?() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(importProjectsAction == nil || !model.isEnabled(.importProjects))
            Divider()
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
                .keyboardShortcut("n", modifiers: [.command, .shift])
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

private struct NewYagartoProjectActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ImportYagartoProjectsActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private extension FocusedValues {
    var newYagartoProjectAction: (() -> Void)? {
        get { self[NewYagartoProjectActionKey.self] }
        set { self[NewYagartoProjectActionKey.self] = newValue }
    }

    var importYagartoProjectsAction: (() -> Void)? {
        get { self[ImportYagartoProjectsActionKey.self] }
        set { self[ImportYagartoProjectsActionKey.self] = newValue }
    }
}

private struct ProjectSheet: Identifiable {
    enum Content {
        case newProject
        case importProjects([URL])
        case importSummary(ProjectImportReport)
    }

    let id = UUID()
    let content: Content
}

@MainActor
private struct NewProjectSheet: View {
    @Bindable var model: AppViewModel
    let onCreated: (CreatedProject?) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var parentDirectory: URL
    @State private var profile: ProfileID
    @State private var isWorking = false

    init(
        model: AppViewModel,
        parentDirectory: URL,
        profile: ProfileID,
        onCreated: @escaping (CreatedProject?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.onCreated = onCreated
        self.onCancel = onCancel
        _parentDirectory = State(initialValue: parentDirectory)
        _profile = State(initialValue: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建 ARM 汇编工程")
                .font(.title2.weight(.semibold))
            Form {
                TextField("工程名称", text: $name)
                    .accessibilityIdentifier("new-project-name")
                LabeledContent("保存位置") {
                    HStack {
                        Text(parentDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("选择…", action: chooseParentDirectory)
                    }
                }
                .accessibilityElement(children: .contain)
                LabeledContent("目标") {
                    profilePicker(selection: $profile)
                        .accessibilityIdentifier("new-project-profile-picker")
                }
                .accessibilityElement(children: .contain)
            }
            .disabled(isWorking)
            Text("将自动创建“工程名/工程名.s”和 yagarto.json；创建后只打开，不自动构建。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = model.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(isWorking ? "正在创建…" : "创建工程") {
                    isWorking = true
                    Task { @MainActor in
                        let created = await model.createProject(ProjectCreationRequest(
                            parentDirectory: parentDirectory,
                            name: name,
                            profile: profile
                        ))
                        isWorking = false
                        onCreated(created)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                .accessibilityIdentifier("new-project-create")
            }
        }
        .padding(24)
        .frame(width: 620)
        .interactiveDismissDisabled(isWorking)
    }

    private func chooseParentDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择新工程的父目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = parentDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        parentDirectory = url
    }
}

@MainActor
private struct ImportProjectsSheet: View {
    @Bindable var model: AppViewModel
    let inputs: [URL]
    let onFinished: (ProjectImportReport) -> Void
    let onCancel: () -> Void

    @State private var profile: ProfileID
    @State private var isWorking = false

    init(
        model: AppViewModel,
        inputs: [URL],
        profile: ProfileID,
        onFinished: @escaping (ProjectImportReport) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.inputs = inputs
        self.onFinished = onFinished
        self.onCancel = onCancel
        _profile = State(initialValue: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导入独立汇编程序")
                .font(.title2.weight(.semibold))
            Text("已选择 \(inputs.count) 个文件或目录。目录仅扫描当前层，每个源码会成为一个独立工程。")
                .foregroundStyle(.secondary)
            LabeledContent("统一目标") {
                profilePicker(selection: $profile)
                    .accessibilityIdentifier("import-profile-picker")
            }
            .accessibilityElement(children: .contain)
            .disabled(isWorking)
            Text("源码内容保持不变；成功发布工程后，原文件会被移入对应子目录。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(isWorking ? "正在导入…" : "开始导入") {
                    isWorking = true
                    Task { @MainActor in
                        if let report = await model.importProjects(ProjectImportRequest(
                            inputs: inputs,
                            profile: profile
                        )) {
                            onFinished(report)
                        }
                        isWorking = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
                .accessibilityIdentifier("import-confirm")
            }
        }
        .padding(24)
        .frame(width: 580)
        .interactiveDismissDisabled(isWorking)
    }
}

@MainActor
private struct ImportSummarySheet: View {
    let report: ProjectImportReport
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入完成")
                .font(.title2.weight(.semibold))
            Text("已创建 \(report.created.count) 个工程")
                .font(.headline)
            Text("跳过 \(report.skipped.count) 个，警告 \(report.warnings.count) 个")
                .foregroundStyle(report.status == .complete ? Color.secondary : Color.orange)
            List {
                if !report.created.isEmpty {
                    Section("已创建") {
                        ForEach(report.created, id: \.projectDirectory) { project in
                            Text(project.projectDirectory.path)
                                .textSelection(.enabled)
                        }
                    }
                }
                if !report.skipped.isEmpty {
                    Section("已跳过") {
                        ForEach(Array(report.skipped.enumerated()), id: \.offset) { _, issue in
                            VStack(alignment: .leading) {
                                Text(issue.sourceURL.path)
                                Text(issue.message).font(.caption).foregroundStyle(.secondary)
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
                if !report.warnings.isEmpty {
                    Section("警告") {
                        ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, issue in
                            VStack(alignment: .leading) {
                                Text(issue.sourceURL.path)
                                Text(issue.message).font(.caption).foregroundStyle(.secondary)
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(minHeight: 210)
            HStack {
                Spacer()
                Button("完成", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 680)
        .frame(minHeight: 360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import-summary")
    }
}

@MainActor
private func profilePicker(selection: Binding<ProfileID>) -> some View {
    Picker("目标 profile", selection: selection) {
        Text("ARM7TDMI").tag(ProfileID.arm7tdmi)
        Text("Cortex-M4").tag(ProfileID.cortexM4)
        Text("STM32F4 Discovery").tag(ProfileID.stm32f4Discovery)
    }
    .labelsHidden()
    .accessibilityLabel("目标 profile")
    .pickerStyle(.menu)
    .frame(width: 190)
}
