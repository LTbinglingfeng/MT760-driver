import Foundation

/// User-facing language. Strings live next to their call sites as Chinese/English pairs instead of
/// `.strings` resources: a SwiftPM resource bundle would have to sit at the `.app` root, which breaks
/// strict code-signature sealing, and the helper/CLI executables have no bundle at all.
public enum MT760Language: String, Sendable, CaseIterable {
    case chinese = "zh-Hans"
    case english = "en"

    /// Short value for `MT760_LANG`.
    public var code: String { self == .chinese ? "zh" : "en" }

    /// Language in use. The App can change it at runtime; read from any thread.
    public static var current: MT760Language { state.withLock { $0 } }

    /// Switches the language for subsequent `L(_:_:)` calls (and helper processes started afterwards).
    public static func apply(_ preference: MT760LanguagePreference) {
        let language: MT760Language
        switch preference {
        case .chinese: language = .chinese
        case .english: language = .english
        case .system: language = launchOverride ?? system
        }
        state.withLock { $0 = language }
    }

    /// The system's preferred language among the supported ones (English if neither matches).
    /// Same resolution as `CFBundleLocalizations` in Info.plist; honours a per-app language setting.
    public static var system: MT760Language {
        let match = Bundle.preferredLocalizations(from: allCases.map(\.rawValue), forPreferences: Locale.preferredLanguages).first
        return match == chinese.rawValue ? .chinese : .english
    }

    /// `MT760_LANG=en|zh` at launch overrides the system language (the App passes it to the helper).
    private static let launchOverride: MT760Language? = {
        guard let value = ProcessInfo.processInfo.environment["MT760_LANG"]?.lowercased(), !value.isEmpty else { return nil }
        return value.hasPrefix("zh") ? .chinese : .english
    }()

    private static let state = LockedValue(launchOverride ?? system)
}

/// The App's stored choice; `.system` follows the system language.
public enum MT760LanguagePreference: String, Sendable, CaseIterable, Identifiable {
    case system, chinese, english
    public var id: Self { self }

    /// Each language is named in itself so it can be found from either language.
    public var title: String {
        switch self {
        case .system: L("跟随系统", "System Default")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// Returns the Chinese or English text for the current language.
@inline(__always)
public func L(_ chinese: String, _ english: String) -> String {
    MT760Language.current == .chinese ? chinese : english
}
