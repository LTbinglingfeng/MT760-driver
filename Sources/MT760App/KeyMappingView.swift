import SwiftUI
import MT760Core

struct KeyMappingView: View {
    @ObservedObject var model: AppModel
    @StateObject private var comboKey = Draft<ComboTarget?>(nil)

    var body: some View {
        Form {
            if let state = model.keys {
                Section(L("按键", "Buttons")) {
                    ForEach(MT760Key.all.filter { !$0.isRoller }, id: \.id) { row($0, state) }
                }
                Section {
                    ForEach(MT760Key.all.filter(\.isRoller), id: \.id) { row($0, state) }
                } header: {
                    Text(L("滚轮", "Scroll Wheel"))
                } footer: {
                    FooterNote(L("选择后立即写入并读回校验。至少保留一个按键为鼠标左键；滚轮功能只能设在滚轮方向上。不支持宏。读取于 \(state.time.formatted(date: .omitted, time: .standard))。",
                                 "Written immediately when selected, then verified by readback. At least one button must stay as the left mouse button; scroll functions can only be assigned to scroll-wheel directions. Macros are not supported. Read at \(state.time.formatted(date: .omitted, time: .standard))."))
                }
            } else {
                LoadingSection(title: L("按键映射", "button mapping"), error: model.keyError, syncing: model.syncing) { model.sync() }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $comboKey.value) { target in
            ComboSheet(key: target.key, initial: model.displayedFunction(keyID: target.key.id),
                       canApply: { model.canAssign($0, to: target.key.id, expectedRegistryID: target.registryID) },
                       apply: { model.assign($0, to: target.key.id, expectedRegistryID: target.registryID) })
        }
        .onChange(of: model.device?.id) { id in
            if comboKey.value?.registryID != id { comboKey.value = nil }
        }
    }

    private func row(_ key: MT760Key, _ state: KeyMappingState) -> some View {
        let slot = state.snapshot.slots[key.id]
        let function = model.displayedFunction(keyID: key.id)
        return LabeledContent {
            HStack(spacing: 8) {
                if model.pendingKeys[key.id] != nil { ProgressView().controlSize(.small) }
                FunctionMenu(model: model, key: key, current: function, rawSlot: slot) {
                    comboKey.value = ComboTarget(key: key, registryID: state.registryID)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                if function != key.defaultFunction {
                    Text(L("默认：", "Default: ") + key.defaultFunction.name).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .help("KeyID \(key.id) · " + L("地址 ", "address ") + "\(hex(MT760KeyCommand.address(keyID: key.id))) · \(hexBytes(slot))")
    }
}

private struct ComboTarget: Identifiable {
    let id = UUID()
    let key: MT760Key
    let registryID: String
}

/// Every writable function in one menu; picking an item writes it right away.
private struct FunctionMenu: View {
    @ObservedObject var model: AppModel
    let key: MT760Key
    let current: KeyFunction?
    let rawSlot: [UInt8]
    let combo: () -> Void

    private static var keyboardGroups: [(title: String, codes: ClosedRange<UInt8>)] { [
        (L("字母", "Letters"), 0x04...0x1D), (L("数字", "Numbers"), 0x1E...0x27), (L("符号与编辑", "Symbols & Editing"), 0x28...0x39),
        (L("功能键", "Function Keys"), 0x3A...0x45), (L("导航", "Navigation"), 0x46...0x52), (L("修饰键", "Modifiers"), 0xE0...0xE7),
    ] }

    var body: some View {
        Menu {
            if current != key.defaultFunction {
                Button(L("恢复默认（\(key.defaultFunction.name)）", "Restore Default (\(key.defaultFunction.name))")) { model.assign(key.defaultFunction, to: key.id) }
                    .disabled(!model.canAssign(key.defaultFunction, to: key.id))
                Divider()
            }
            Menu(L("鼠标按键", "Mouse Buttons")) {
                ForEach(MouseButton.allCases, id: \.self) { option($0.name, .mouse($0)) }
            }
            Menu(L("DPI 与特殊功能", "DPI & Special")) {
                ForEach(DPIAction.allCases, id: \.self) { option($0.name, .dpi($0)) }
                Divider()
                option(KeyFunction.reportRateSwitch.name, .reportRateSwitch)
                option(KeyFunction.sniper.name, .sniper)
                option(KeyFunction.fire.name, .fire)
            }
            if key.isRoller {
                Menu(L("滚轮", "Scroll Wheel")) {
                    option(L("上滚", "Scroll Up"), .verticalScroll(up: true))
                    option(L("下滚", "Scroll Down"), .verticalScroll(up: false))
                    option(L("左滚", "Scroll Left"), .horizontalScroll(right: false))
                    option(L("右滚", "Scroll Right"), .horizontalScroll(right: true))
                }
            }
            Menu(L("多媒体", "Multimedia")) {
                ForEach(MT760KeyTables.multimedia, id: \.usage) { option($0.name, .multimedia($0.usage)) }
            }
            Menu(L("快捷键", "Shortcuts")) {
                ForEach(MT760KeyTables.shortcuts, id: \.function) { option($0.name, $0.function) }
            }
            Menu(L("键盘单键", "Keyboard Key")) {
                ForEach(Self.keyboardGroups, id: \.title) { group in
                    Menu(group.title) {
                        ForEach(MT760KeyTables.keys.filter { group.codes.contains($0.code) }, id: \.code) {
                            option($0.name, .keyboard($0.code))
                        }
                    }
                }
            }
            Button(L("自定义组合键…", "Custom Key Combination…"), action: combo)
            Divider()
            option(KeyFunction.disabled.name, .disabled)
        } label: {
            Text(current?.name ?? L("未识别 · ", "Unrecognized · ") + hexBytes(rawSlot))
                .foregroundStyle(current == nil ? Color.orange : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func option(_ name: String, _ function: KeyFunction) -> some View {
        Toggle(name, isOn: Binding(get: { function == current }, set: { _ in model.assign(function, to: key.id) }))
            .disabled(!model.canAssign(function, to: key.id))
    }
}

/// One modifier plus one key (MT760 limit: MaxModifyNum 1, MaxCodeNum 1).
private struct ComboSheet: View {
    let key: MT760Key
    let canApply: (KeyFunction) -> Bool
    let apply: (KeyFunction) -> Void
    @StateObject private var modifier: Draft<Int>
    @StateObject private var code: Draft<UInt8>
    @Environment(\.dismiss) private var dismiss

    init(key: MT760Key, initial: KeyFunction?, canApply: @escaping (KeyFunction) -> Bool, apply: @escaping (KeyFunction) -> Void) {
        self.key = key
        self.canApply = canApply
        self.apply = apply
        if case .combo(let modifiers, let code) = initial, modifiers.nonzeroBitCount == 1 {
            _modifier = StateObject(wrappedValue: Draft(modifiers.trailingZeroBitCount))
            _code = StateObject(wrappedValue: Draft(code))
        } else {
            _modifier = StateObject(wrappedValue: Draft(0))
            _code = StateObject(wrappedValue: Draft(0x04))
        }
    }

    private var function: KeyFunction { .combo(modifiers: UInt8(1 << modifier.value), key: code.value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("自定义组合键", "Custom Key Combination")).font(.headline)
                Text(L("为“\(key.name)”设置一个修饰键加一个按键。", "Set one modifier plus one key for “\(key.name)”.")).font(.callout).foregroundStyle(.secondary)
            }
            Text((MT760KeyTables.modifierNames(UInt8(1 << modifier.value)) + [MT760KeyTables.keyName(code.value)]).joined(separator: " + "))
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(L("修饰键", "Modifier")).foregroundStyle(.secondary)
                    Picker(L("修饰键", "Modifier"), selection: $modifier.value) {
                        ForEach(0..<MT760KeyTables.modifiers.count, id: \.self) { Text(MT760KeyTables.modifiers[$0]).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text(L("按键", "Key")).foregroundStyle(.secondary)
                    Picker(L("按键", "Key"), selection: $code.value) {
                        ForEach(MT760KeyTables.keys.filter { !(0xE0...0xE7).contains($0.code) }, id: \.code) {
                            Text($0.name).tag($0.code)
                        }
                    }
                    .labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button(L("取消", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("应用", "Apply")) { apply(function); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply(function))
            }
        }
        .padding(22)
        .frame(width: 360)
    }
}
