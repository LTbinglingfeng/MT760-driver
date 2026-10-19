import SwiftUI
import MT760Core

struct DPIView: View {
    @ObservedObject var model: AppModel
    @StateObject private var editor = Draft(800)

    private var draft: Int {
        get { editor.value }
        nonmutating set { editor.value = newValue }
    }

    var body: some View {
        Form {
            if let state = model.dpi {
                content(state)
            } else {
                LoadingSection(title: "DPI", error: model.dpiError, syncing: model.syncing) { model.sync() }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: resetDraft)
        .onChange(of: model.dpi?.snapshot) { _ in resetDraft() }
    }

    @ViewBuilder private func content(_ state: DPIState) -> some View {
        let snapshot = state.snapshot
        let shownGear = model.pendingGear ?? snapshot.currentGear

        Section {
            HeroValue(value: "\(snapshot.levels[shownGear - 1])", unit: "DPI",
                      caption: L("第 \(shownGear) 档 · 共启用 \(snapshot.activeCount) 档", "Level \(shownGear) · \(snapshot.activeCount) levels enabled"))
        }

        Section {
            GearStrip(levels: snapshot.levels, activeCount: snapshot.activeCount, current: shownGear) {
                model.switchGear(to: $0)
            }
        } header: {
            Text(L("档位", "Levels"))
        } footer: {
            FooterNote(L("点击即切换当前档位。鼠标上的 DPI 键也会切换档位，回到本窗口时自动同步。",
                         "Click to switch the current level. The DPI button on the mouse also switches levels; the App syncs automatically when you return to this window."))
        }

        Section {
            valueEditor(current: snapshot.currentDPI)
        } header: {
            Text(L("第 \(snapshot.currentGear) 档数值", "Level \(snapshot.currentGear) Value"))
        } footer: {
            FooterNote(L("50–4000 DPI，步进 50。只修改当前档位，其他档位与档位数量保持不变。读取于 \(state.time.formatted(date: .omitted, time: .standard))。",
                         "50–4000 DPI in steps of 50. Only the current level changes; other levels and the number of levels stay the same. Read at \(state.time.formatted(date: .omitted, time: .standard))."))
        }
    }

    private func valueEditor(current: Int) -> some View {
        let writing = model.pendingDPI != nil
        let dirty = draft != current && !writing
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Slider(value: sliderValue, in: Double(MT760DPICommand.dpiRange.lowerBound)...Double(MT760DPICommand.dpiRange.upperBound)) {
                    Text("DPI")
                } minimumValueLabel: {
                    Text("50").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("4000").font(.caption).foregroundStyle(.secondary)
                }
                .labelsHidden()
                TextField("DPI", value: $editor.value, format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
                    .onSubmit(apply)
                Stepper("DPI", value: $editor.value, in: MT760DPICommand.dpiRange, step: MT760DPICommand.dpiStep)
                    .labelsHidden()
            }
            if writing || dirty {
                HStack(spacing: 10) {
                    if writing {
                        ProgressView().controlSize(.small)
                        Text(L("正在写入…", "Writing…")).font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: "\(current) → \(MT760DPICommand.normalizedTarget(draft)) DPI")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button(L("还原", "Revert")) { draft = current }
                        Button(L("应用", "Apply"), action: apply)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(minHeight: 24)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.15), value: dirty || writing)
    }

    private var sliderValue: Binding<Double> {
        Binding(get: { Double(MT760DPICommand.normalizedTarget(draft)) },
                set: { draft = MT760DPICommand.normalizedTarget(Int($0.rounded())) })
    }

    private func apply() {
        draft = MT760DPICommand.normalizedTarget(draft)
        model.applyDPI(draft)
    }

    private func resetDraft() {
        if let dpi = model.dpi?.snapshot.currentDPI { draft = dpi }
    }
}

/// Seven storage slots; enabled ones are clickable, the current one carries the accent.
private struct GearStrip: View {
    let levels: [Int]
    let activeCount: Int
    let current: Int
    let select: (Int) -> Void
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...levels.count, id: \.self) { gear in
                chip(gear)
            }
        }
        .padding(.vertical, 4)
        .animation(reduceMotion ? nil : calmSpring, value: current)
    }

    private func chip(_ gear: Int) -> some View {
        let enabled = gear <= activeCount
        let isCurrent = gear == current
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { select(gear) } label: {
            VStack(spacing: 3) {
                Text(verbatim: String(gear))
                    .font(.caption2.weight(.semibold))
                    .opacity(isCurrent ? 0.8 : 0.6)
                Text(verbatim: String(levels[gear - 1]))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                if !enabled {
                    Text(L("未启用", "Disabled")).font(.caption2)
                }
            }
            .foregroundStyle(isCurrent ? AnyShapeStyle(Color.white) : enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                ZStack {
                    shape.fill(Color.primary.opacity(enabled ? 0.06 : 0.025))
                    if isCurrent {
                        shape.fill(Color.accentColor).matchedGeometryEffect(id: "current", in: namespace)
                    }
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .help(enabled ? (isCurrent ? L("当前档位", "Current level") : L("切换到第 \(gear) 档", "Switch to level \(gear)"))
                      : L("第 \(gear) 档未启用", "Level \(gear) is disabled"))
        .accessibilityLabel(L("第 \(gear) 档，\(levels[gear - 1]) DPI\(isCurrent ? "，当前" : enabled ? "" : "，未启用")",
                              "Level \(gear), \(levels[gear - 1]) DPI\(isCurrent ? ", current" : enabled ? "" : ", disabled")"))
    }
}
