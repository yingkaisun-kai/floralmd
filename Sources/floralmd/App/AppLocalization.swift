import Foundation

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("FloralMD.appLanguageDidChange")
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: Self { self }

    var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    func displayName(in interfaceLanguage: AppLanguage) -> String {
        switch self {
        case .system: return AppCopy.text("System Default", "跟随系统", language: interfaceLanguage)
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

enum AppCopy {
    static func text(_ english: String, _ simplifiedChinese: String,
                     language: AppLanguage = AppSettings.interfaceLanguage) -> String {
        language.resolved == .simplifiedChinese ? simplifiedChinese : english
    }
}
