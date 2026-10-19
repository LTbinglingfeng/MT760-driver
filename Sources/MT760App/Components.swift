import SwiftUI
import MT760Core

/// View-local state holder used with `@StateObject`. The Command Line Tools toolchain ships the
/// macro-based `@State` without its SwiftUIMacros plugin, so `@State` does not compile here.
final class Draft<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

/// Critically damped: settles without overshoot (UI state changes, not flicks).
let calmSpring = Animation.spring(response: 0.3, dampingFraction: 1)

/// Large, centered readout used at the top of each settings page.
struct HeroValue: View {
    let value: String
    let unit: String
    let caption: String

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .tracking(-1)
                    .monospacedDigit()
                    .numericTransition()
                Text(unit)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .animation(calmSpring, value: value)
        .accessibilityElement(children: .combine)
    }
}

/// Section footer text. Grouped-form footers align trailing by default (meant for buttons).
struct FooterNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }
}

/// Placeholder shown while a section has no verified data yet.
struct LoadingSection: View {
    let title: String
    let error: String?
    let syncing: Bool
    let retry: () -> Void

    var body: some View {
        Section {
            VStack(spacing: 10) {
                if let error, !syncing {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.orange)
                    Text(L("无法读取\(title)", "Could not read \(title)")).font(.headline)
                    Text(error)
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: 420)
                    Button(L("重新读取", "Read Again"), action: retry).padding(.top, 4)
                } else {
                    ProgressView().controlSize(.small)
                    Text(L("正在读取\(title)…", "Reading \(title)…")).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        }
    }
}

/// Card message with an icon, for states that block every setting. Hosted in a grouped Form like
/// the settings pages (a bare VStack detail left the sidebar List undrawn in offscreen renders).
struct MessagePane<Actions: View>: View {
    let symbol: String
    var tint: Color = .secondary
    let title: String
    let message: String
    var note: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        Form {
            Section { content }
        }
        .formStyle(.grouped)
    }

    private var content: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(tint)
                .padding(.bottom, 4)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note)
                    .font(.callout).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions.padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: toast.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(toast.succeeded ? Color.green : Color.orange)
            Text(toast.text)
                .font(.callout)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
        .frame(maxWidth: 480)
        .accessibilityElement(children: .combine)
    }
}

/// Subtle scale on press so custom controls acknowledge the click immediately.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    @ViewBuilder func numericTransition() -> some View {
        if #available(macOS 14.0, *) { contentTransition(.numericText()) } else { self }
    }
}
