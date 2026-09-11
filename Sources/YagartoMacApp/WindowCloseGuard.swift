// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import YagartoAppSupport

@MainActor
struct WindowCloseGuard: NSViewRepresentable {
    let model: AppViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> WindowHookView {
        let view = WindowHookView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ view: WindowHookView, context: Context) {
        context.coordinator.model = model
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: WindowHookView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var model: AppViewModel
        private weak var window: NSWindow?
        private weak var previousDelegate: (any NSWindowDelegate)?
        private var bypassNextClose = false

        init(model: AppViewModel) {
            self.model = model
        }

        func attach(to window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            detach()
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
        }

        func detach() {
            if let window, window.delegate === self {
                window.delegate = previousDelegate
            }
            window = nil
            previousDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if bypassNextClose {
                bypassNextClose = false
                return previousDelegate?.windowShouldClose?(sender) ?? true
            }
            switch ClosePolicy.action(
                isDirty: model.document?.isDirty ?? false,
                state: model.state
            ) {
            case .allow:
                return previousDelegate?.windowShouldClose?(sender) ?? true
            case .stopThenClose:
                closeAfterCleanup(sender)
                return false
            case .confirmUnsaved:
                return confirmUnsavedBeforeClosing(sender)
            }
        }

        private func confirmUnsavedBeforeClosing(_ window: NSWindow) -> Bool {
            let alert = NSAlert()
            alert.messageText = "源码尚未保存"
            alert.informativeText = "关闭窗口前保存修改吗？活动调试器也会被有界停止。"
            alert.addButton(withTitle: "保存并关闭")
            alert.addButton(withTitle: "不保存")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                Task { @MainActor [weak self, weak window] in
                    guard let self, let window else { return }
                    await model.save()
                    guard model.document?.isDirty != true else { return }
                    closeAfterCleanup(window)
                }
            case .alertSecondButtonReturn:
                closeAfterCleanup(window)
            default:
                break
            }
            return false
        }

        private func closeAfterCleanup(_ window: NSWindow) {
            Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                await model.close()
                bypassNextClose = true
                window.performClose(nil)
            }
        }
    }
}

@MainActor
final class WindowHookView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
