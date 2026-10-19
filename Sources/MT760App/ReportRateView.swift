import SwiftUI
import MT760Core

struct ReportRateView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            if let state = model.rate {
                let hz = model.pendingRate ?? state.snapshot.wiredHz
                Section {
                    HeroValue(value: "\(hz)", unit: "Hz", caption: L("每 \(interval(hz)) 向电脑报告一次位置", "Reports its position to the computer every \(interval(hz))"))
                }
                Section {
                    Picker(L("回报率", "Report Rate"), selection: Binding(get: { hz }, set: { model.applyRate($0) })) {
                        ForEach(MT760ReportRateCommand.supportedRates, id: \.self) { rate in
                            Text(verbatim: "\(rate) Hz").tag(rate)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.vertical, 4)
                    if model.pendingRate != nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("正在写入…", "Writing…")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(L("回报率", "Report Rate"))
                } footer: {
                    FooterNote(L("选择后立即写入并读回校验。回报率越高响应越及时，CPU 占用也略高；切换时鼠标可能短暂重新连接。读取于 \(state.time.formatted(date: .omitted, time: .standard))。",
                                 "Written immediately when selected, then verified by readback. A higher report rate is more responsive but uses slightly more CPU; the mouse may briefly reconnect when switching. Read at \(state.time.formatted(date: .omitted, time: .standard))."))
                }
            } else {
                LoadingSection(title: L("回报率", "report rate"), error: model.rateError, syncing: model.syncing) { model.sync() }
            }
        }
        .formStyle(.grouped)
    }

    private func interval(_ hz: Int) -> String {
        let ms = 1000.0 / Double(max(hz, 1))
        return ms == ms.rounded() ? "\(Int(ms)) ms" : String(format: "%.1f ms", ms)
    }
}
