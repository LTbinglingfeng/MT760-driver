import AppKit
import SwiftUI
import MT760Core

struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var pane = Draft<Pane?>(.dpi)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: Pane { pane.value ?? .dpi }

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, pane: $pane.value)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(current.title)
                .navigationSubtitle(model.syncStatus)
                .overlay(alignment: .bottom) { toastHost }
        }
        .frame(minWidth: 760, minHeight: 540)
        .toolbar {
            ToolbarItem {
                Button { model.sync() } label: { Label(L("重新读取", "Read Again"), systemImage: "arrow.clockwise") }
                    .help(L("从鼠标重新读取全部设置（⌘R）", "Read all settings from the mouse again (⌘R)"))
                    .disabled(model.device == nil || model.syncing)
            }
            ToolbarItem {
                LanguageMenu(model: model)
            }
        }
        .task {
            await model.ensureInputAccess()
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.appDidBecomeActive()
        }
    }

    @ViewBuilder private var detail: some View {
        if current == .info {
            DeviceInfoView(model: model)
        } else if model.device == nil {
            connectPane
        } else if model.needsPermission {
            permissionPane
        } else {
            switch current {
            case .dpi: DPIView(model: model)
            case .rate: ReportRateView(model: model)
            case .keys: KeyMappingView(model: model)
            case .info: EmptyView()
            }
        }
    }

    private var toastHost: some View {
        ZStack {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 22)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 14)))
                    .onTapGesture { model.toast = nil }
            }
        }
        .animation(calmSpring, value: model.toast)
    }

    private var connectPane: some View {
        MessagePane(
            symbol: "cable.connector",
            title: L("连接 MT760", "Connect MT760"),
            message: model.hasNonUSBInterface
                ? L("检测到蓝牙或其他非 USB 连接。修改设置需要用支持数据传输的 USB 线直接连接鼠标。",
                    "A Bluetooth or other non-USB connection was detected. Changing settings requires connecting the mouse directly with a USB data cable.")
                : L("使用支持数据传输的 USB 线连接鼠标。仅能充电的线不会建立数据连接。",
                    "Connect the mouse with a USB cable that supports data transfer. Charge-only cables do not establish a data connection."),
            note: L("连接后自动读取 DPI、回报率与按键。如果仍未出现，请检查线材、转接器和鼠标连接模式，或运行 README 中的 hidutil 命令核对。",
                    "DPI, report rate and buttons are read automatically once connected. If the mouse still does not appear, check the cable, adapter and the mouse's connection mode, or run the hidutil command from the README.")
        ) { EmptyView() }
    }

    private var permissionPane: some View {
        MessagePane(
            symbol: "hand.raised",
            tint: .orange,
            title: L("需要“输入监控”权限", "Input Monitoring Permission Required"),
            message: L("MT760 的配置接口在系统中属于键盘类 HID，macOS 要求授权后才允许打开。本 App 不读取键盘或鼠标输入事件。",
                       "The MT760 configuration interface is a keyboard-class HID device, so macOS requires permission before it can be opened. This App does not read keyboard or mouse input events."),
            note: L("在 系统设置 → 隐私与安全性 → 输入监控 中打开“MT760 Control”，然后重新打开 App。重新构建（签名变化）后可能需要重新授权。当前：",
                    "Turn on “MT760 Control” in System Settings → Privacy & Security → Input Monitoring, then reopen the App. After a rebuild (signature change) you may need to grant it again. Current: ")
                + (model.inputAccess == .denied ? L("未授权", "denied") : L("未确定", "not determined"))
        ) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button(L("打开系统设置", "Open System Settings")) { model.openInputMonitoringSettings() }
                    Button(L("重新打开 App", "Reopen App")) { model.relaunch() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                }
                Button(L("再次申请权限", "Request Permission Again")) { Task { await model.requestInputAccess() } }
                    .buttonStyle(.link)
            }
        }
    }
}

/// Switches the UI language immediately; the choice is remembered across launches.
struct LanguageMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            LanguagePicker(model: model)
        } label: {
            Label(L("语言", "Language"), systemImage: "globe")
        }
        .help(L("切换界面语言", "Change the interface language"))
    }
}

struct LanguagePicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Picker(L("语言", "Language"), selection: $model.languagePreference) {
            ForEach(MT760LanguagePreference.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
    }
}

private struct Sidebar: View {
    @ObservedObject var model: AppModel
    @Binding var pane: Pane?

    var body: some View {
        List(selection: $pane) {
            ForEach(Pane.allCases) { item in
                HStack {
                    Label(item.title, systemImage: item.symbol)
                    Spacer(minLength: 8)
                    Text(summary(item))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .tag(item)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { deviceBadge }
    }

    private var deviceBadge: some View {
        HStack(spacing: 10) {
            Image(systemName: "computermouse.fill")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("MT760").font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.device != nil ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(connection).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    private var connection: String {
        if model.device != nil { return L("USB 已连接", "USB connected") }
        return model.hasNonUSBInterface ? L("仅非 USB 连接", "Non-USB only") : L("未连接", "Not connected")
    }

    private func summary(_ item: Pane) -> String {
        switch item {
        case .dpi: model.dpi.map { "\($0.snapshot.currentDPI)" } ?? ""
        case .rate: model.rate.map { "\($0.snapshot.wiredHz) Hz" } ?? ""
        case .keys:
            model.keys.map { state in
                let changed = MT760Key.all.filter { state.snapshot.function(keyID: $0.id) != $0.defaultFunction }.count
                return changed == 0 ? L("默认", "Default") : L("\(changed) 项已改", "\(changed) changed")
            } ?? ""
        case .info: ""
        }
    }
}
