// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import YagartoAppSupport

@main
@MainActor
struct YagartoMacApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle
    @State private var model: AppViewModel
    private let runtime: AppRuntime

    init() {
        let runtime = AppRuntime.make()
        self.runtime = runtime
        _model = State(initialValue: runtime.model)
    }

    var body: some Scene {
        WindowGroup("YAGARTO Mac") {
            WorkbenchView(model: model, exampleURL: runtime.exampleURL)
                .task { lifecycle.model = model }
        }
        .defaultSize(width: 1_280, height: 820)
        .commands {
            WorkbenchCommands(model: model)
            CommandGroup(replacing: .appInfo) {
                Button("关于 YAGARTO Mac") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "YAGARTO Mac",
                        .applicationVersion: "0.4.0",
                        .credits: NSAttributedString(
                            string: "非官方 YAGARTO 兼容实现\nGNU GPL-3.0-or-later"
                        )
                    ])
                }
            }
        }
    }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppViewModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.document?.isDirty == true {
            let alert = NSAlert()
            alert.messageText = "源码尚未保存"
            alert.informativeText = "退出前保存修改吗？调试器会在退出前有界停止。"
            alert.addButton(withTitle: "保存并退出")
            alert.addButton(withTitle: "不保存")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                Task {
                    await model.save()
                    guard model.document?.isDirty != true else {
                        sender.reply(toApplicationShouldTerminate: false)
                        return
                    }
                    await model.close()
                    sender.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            case .alertSecondButtonReturn:
                Task {
                    await model.close()
                    sender.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            default:
                return .terminateCancel
            }
        }
        if model.isEnabled(.stop) {
            Task {
                await model.close()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}
