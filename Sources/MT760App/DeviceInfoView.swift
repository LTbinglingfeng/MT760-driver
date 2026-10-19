import SwiftUI
import MT760Core

/// Everything technical lives here so the settings pages can stay focused on use.
struct DeviceInfoView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            if let device = model.device {
                deviceSection(device)
                descriptorSection(device)
            } else {
                Section(L("设备", "Device")) {
                    Text(L("未连接 MT760 配置接口（USB 24AE:4500，接口 1）。", "MT760 configuration interface (USB 24AE:4500, interface 1) is not connected."))
                        .foregroundStyle(.secondary)
                }
            }
            rawDataSection
            recordsSection
            notesSection
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("设备诊断", "Device Diagnostics"))
                        Text(scanNote).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("导出诊断…", "Export Diagnostics…")) { model.exportDiagnostics() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var scanNote: String {
        var parts: [String] = []
        if model.hiddenInterfaceCount > 0 {
            parts.append(L("另有 \(model.hiddenInterfaceCount) 个 Rapoo 接口不用于配置，已隐藏；诊断包含全部接口",
                           "\(model.hiddenInterfaceCount) other Rapoo interface(s) not used for configuration are hidden; diagnostics include all interfaces"))
        }
        if let date = model.lastScan {
            parts.append(L("最近扫描 \(date.formatted(date: .omitted, time: .standard)) · 每 2 秒更新",
                           "Last scan \(date.formatted(date: .omitted, time: .standard)) · updated every 2 s"))
        }
        return parts.joined(separator: L("。", ". "))
    }

    // MARK: Device

    private func deviceSection(_ device: DeviceInfo) -> some View {
        Section {
            row(L("产品", "Product"), device.product)
            row(L("状态", "Status"), device.status)
            row("VID / PID", "\(hex(device.vendorID)) / \(hex(device.productID))")
            row(L("连接方式", "Transport"), device.transport)
            row(L("USB 接口号", "USB interface"), device.usbInterfaceNumber.map { String($0) } ?? L("未提供", "Not provided"))
            row(L("主 Usage Page / Usage", "Primary Usage Page / Usage"), "\(hex(device.primaryUsage.page)) / \(hex(device.primaryUsage.usage))")
            row(L("所有 Usage", "All usages"), device.usages.map { "\(hex($0.page))/\(hex($0.usage))" }.joined(separator: ", "))
            row(L("系统报告大小上限", "Max report sizes (system)"), "Input \(device.maxInputBytes) · Output \(device.maxOutputBytes) · Feature \(device.maxFeatureBytes) B")
            row("Registry ID", device.id)
        } header: {
            Text(L("设备", "Device"))
        } footer: {
            FooterNote(L("接口匹配基于实时拓扑筛选，不代表已验证型号或固件。",
                         "The interface is matched by live topology filtering; this does not verify the model or firmware."))
        }
    }

    private func descriptorSection(_ device: DeviceInfo) -> some View {
        Section {
            ForEach(device.summary.reports) { report in
                LabeledContent {
                    if device.summary.lengthsAreReliable {
                        Text(L("\(report.bitCount) bit · \(report.payloadBytes) B / 线上 \(report.wireBytes) B",
                               "\(report.bitCount) bit · \(report.payloadBytes) B / on wire \(report.wireBytes) B")).monospacedDigit()
                    } else {
                        Text(L("长度未确认 · 描述符有警告", "Length unconfirmed · descriptor has warnings"))
                    }
                } label: {
                    Text("\(report.kind.rawValue.capitalized) · ID \(hex(report.reportID))").monospacedDigit()
                }
            }
            ForEach(Array(device.summary.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            DisclosureGroup(L("原始描述符 · \(device.descriptor.count) 字节", "Raw descriptor · \(device.descriptor.count) bytes")) {
                mono(hexBytes(device.descriptor))
            }
        } header: {
            Text(L("HID 报告描述符", "HID Report Descriptor"))
        } footer: {
            FooterNote(L("长度不含 Report ID；线上长度对非零 ID 额外加 1 字节。描述符不能证明配置命令有效。",
                         "Lengths exclude the Report ID; the on-wire length adds 1 byte for non-zero IDs. A descriptor does not prove that a configuration command works."))
        }
    }

    // MARK: Raw configuration

    @ViewBuilder private var rawDataSection: some View {
        if model.dpi != nil || model.rate != nil || model.keys != nil {
            Section {
                if let state = model.dpi {
                    let snapshot = state.snapshot
                    row(L("DPI 七槽", "DPI slots"), L("\(AppModel.levels(snapshot)) · 启用 \(snapshot.activeCount) 档 · 当前第 \(snapshot.currentGear) 档",
                                                    "\(AppModel.levels(snapshot)) · \(snapshot.activeCount) enabled · current level \(snapshot.currentGear)"))
                    LabeledContent(L("DPI 配置 0x638 · 20 B", "DPI config 0x638 · 20 B")) { mono(hexBytes(state.baseline)) }
                }
                if let state = model.rate {
                    row(L("无线回报率字节", "Wireless report-rate byte"), AppModel.wireless(state.snapshot))
                    LabeledContent(L("回报率 0x630 · 8 B", "Report rate 0x630 · 8 B")) { mono(hexBytes(state.snapshot.block)) }
                }
                if let state = model.keys {
                    DisclosureGroup(L("按键槽 0x600 · 11 × 4 B（\(state.source) \(state.time.formatted(date: .omitted, time: .standard))）",
                                      "Button slots 0x600 · 11 × 4 B (\(state.source) \(state.time.formatted(date: .omitted, time: .standard)))")) {
                        ForEach(MT760Key.all, id: \.id) { key in
                            LabeledContent("\(key.name) · \(hex(MT760KeyCommand.address(keyID: key.id)))" as String) {
                                mono(hexBytes(state.snapshot.slots[key.id]))
                            }
                        }
                    }
                }
            } header: {
                Text(L("原始配置数据", "Raw Configuration Data"))
            } footer: {
                FooterNote(L("来自最近一次读取或写入事务的读回；不实时跟踪设备，切回本窗口或按 ⌘R 时重新读取。",
                             "From the latest read or write-transaction readback. The device is not tracked live; it is re-read when you return to this window or press ⌘R."))
            }
        }
    }

    // MARK: Records

    private var recordsSection: some View {
        Section {
            if model.records.isEmpty {
                Text(L("尚无记录。", "No records yet.")).foregroundStyle(.secondary)
            }
            ForEach(model.records.prefix(30)) { record in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: record.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(record.succeeded ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title)
                        Text(record.detail)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    Text(record.time.formatted(date: .omitted, time: .standard))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button { model.export(record) } label: { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.borderless)
                        .help(L("导出原始记录 JSON", "Export raw record JSON"))
                }
            }
        } header: {
            Text(L("操作记录", "Activity Log"))
        } footer: {
            FooterNote(L("每条记录包含各步骤原始请求 / 响应 / IOReturn；App 会从原始记录重新推导并校验辅助进程的结论。设备移除后记录保留。",
                         "Each record contains the raw request / response / IOReturn of every step; the App re-derives and checks the helper's conclusions from the raw record. Records are kept after the device is removed."))
        }
    }

    // MARK: Notes

    private var notesSection: some View {
        Section {
            DisclosureGroup(L("读取与写入方式", "How Reads and Writes Work")) {
                note(L("连接鼠标、切回本窗口或按 ⌘R 时，由独立辅助进程发送固定读请求读取 DPI、回报率与按键，不写配置；A HUB Office 运行时不访问设备。",
                       "When the mouse connects, you return to this window or press ⌘R, a separate helper process sends fixed read requests for DPI, report rate and buttons without writing any configuration. The device is not accessed while A HUB Office is running."))
                note(L("每次修改都是一次固定事务：现场读取并与界面所示数据逐字节比对 → 写入一次 → 读回校验。不一致即不写入；任何请求都不重发、不自动回滚。失败后自动重新读取，以设备实际状态为准。",
                       "Every change is one fixed transaction: fresh read compared byte by byte with the data shown → one write → readback verification. On any mismatch nothing is written; no request is ever resent or automatically rolled back. After a failure the device is re-read and its actual state is shown."))
                note(L("DPI 数值：只替换当前档位的 2 字节，其他槽、档位数、当前档位与辅助字节保持不变（官方 setDPIListInfo）。",
                       "DPI value: only the 2 bytes of the current level are replaced; other slots, the level count, the current level and auxiliary bytes are unchanged (official setDPIListInfo)."))
                note(L("切换档位：只写 0x648（官方 setCurDPIGear）；与官方一致，会交换 0x64A / 0x64B 两个语义未知的字节，记录中会列出。",
                       "Level switch: writes only 0x648 (official setCurDPIGear). Like the official app, it swaps the two bytes 0x64A / 0x64B whose meaning is unknown; the record lists this."))
                note(L("回报率：与官方 setReturnRate 一致，有线与无线字节写为同一编码；仅提供 125 / 250 / 500 / 1000 Hz。",
                       "Report rate: like the official setReturnRate, the wired and wireless bytes are written with the same code; only 125 / 250 / 500 / 1000 Hz are offered."))
                note(L("按键：编码来自官方 MouseForTelink::setKey；一次只改一个按键的 4 字节，读回时相邻字节必须不变。",
                       "Buttons: encodings come from the official MouseForTelink::setKey; only one button's 4 bytes change at a time, and neighboring bytes must be unchanged on readback."))
            }
            DisclosureGroup(L("未提供的功能", "Not Available")) {
                HStack(spacing: 8) {
                    ForEach([L("档位增删", "Add/remove levels"), L("宏", "Macros"), "Profile", L("复位", "Reset"), L("固件升级", "Firmware update")], id: \.self) { title in
                        Label(title, systemImage: "lock")
                            .font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                .padding(.vertical, 4)
                note(L("写入的设置保存在鼠标中，拔插或断电后仍然保留。", "Written settings are stored in the mouse and persist after unplugging or power loss."))
            }
        } header: {
            Text(L("说明", "Notes"))
        }
    }

    // MARK: Helpers

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value.isEmpty ? L("未提供", "Not provided") : value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
    }
}
