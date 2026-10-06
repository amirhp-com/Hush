import Foundation
import SwiftUI

/// English text is the key. Persian lives in `FarsiStrings.table`; anything missing falls back to English.
final class Loc: ObservableObject {
    static let shared = Loc()

    @Published var language: String

    private init() {
        language = UserDefaults.standard.string(forKey: "uiLanguage")
            ?? (Locale.preferredLanguages.first?.hasPrefix("fa") == true ? "fa" : "en")
    }

    var isRTL: Bool { language == "fa" }
    var direction: LayoutDirection { isRTL ? .rightToLeft : .leftToRight }
    var locale: Locale { Locale(identifier: language == "fa" ? "fa_IR" : "en_US") }

    func t(_ key: String) -> String {
        language == "fa" ? (FarsiStrings.table[key] ?? key) : key
    }
}

func L(_ key: String) -> String { Loc.shared.t(key) }

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: Loc.shared.t(key), locale: Loc.shared.locale, arguments: args)
}
