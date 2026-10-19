import AppKit
import SwiftUI
import MT760Core

@main
struct MT760App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("MT760 Control", id: "main") { ContentView(model: model) }
            .defaultSize(width: 900, height: 640)
            .commands {
                CommandGroup(after: .importExport) {
                    Button(L("导出诊断…", "Export Diagnostics…")) { model.exportDiagnostics() }
                        .keyboardShortcut("e", modifiers: .command)
                }
                CommandGroup(after: .sidebar) {
                    Divider()
                    Menu(L("语言", "Language")) { LanguagePicker(model: model) }
                }
                CommandMenu(L("设备", "Device")) {
                    Button(L("重新读取", "Read Again")) { model.sync() }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(model.device == nil || model.syncing)
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
