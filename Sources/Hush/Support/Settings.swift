import AppKit
import Foundation
import HushCore
import SwiftUI

enum BackgroundMode: String, CaseIterable, Identifiable, Codable {
    case glass, translucent, solid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: return L("Liquid Glass")
        case .translucent: return L("Translucent")
        case .solid: return L("Solid")
        }
    }
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("System")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum ProxyKind: String, CaseIterable, Identifiable {
    case none, http, socks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return L("No proxy")
        case .http: return "HTTP/HTTPS"
        case .socks: return "SOCKS5"
        }
    }
}

enum ModelSource: String, CaseIterable, Identifiable {
    case huggingface, mirror
    var id: String { rawValue }
    var host: String { self == .huggingface ? "https://huggingface.co" : "https://hf-mirror.com" }
    var title: String { self == .huggingface ? "huggingface.co" : "hf-mirror.com" }
}

/// Spoken languages offered in the pickers. whisper.cpp supports ~100; these are the common ones.
enum SpokenLanguage {
    static let all: [(code: String, name: String)] = [
        ("auto", "Auto-detect"), ("fa", "فارسی"), ("en", "English"), ("ar", "العربية"), ("tr", "Türkçe"),
        ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"), ("ru", "Русский"),
        ("zh", "中文"), ("ja", "日本語"), ("ko", "한국어"), ("hi", "हिन्दी"), ("ur", "اردو"), ("pt", "Português"),
        ("nl", "Nederlands"), ("uk", "Українська"), ("az", "Azərbaycan"), ("ku", "Kurdî")
    ]

    static func name(_ code: String) -> String {
        if code == "auto" { return L("Auto-detect") }
        return all.first { $0.code == code }?.name ?? code
    }
}

/// Everything the user can change, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // General
    @Published var uiLanguage: String { didSet { d.set(uiLanguage, forKey: "uiLanguage"); Loc.shared.language = uiLanguage } }
    @Published var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    @Published var keepAwakeWhileWorking: Bool { didSet { d.set(keepAwakeWhileWorking, forKey: "keepAwake") } }
    @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }
    @Published var watchFolders: [String] { didSet { d.set(watchFolders, forKey: "watchFolders"); Task { @MainActor in WatchFolders.shared.restart() } } }

    // Appearance
    @Published var backgroundMode: BackgroundMode { didSet { d.set(backgroundMode.rawValue, forKey: "bgMode") } }
    @Published var backgroundColorHex: String { didSet { d.set(backgroundColorHex, forKey: "bgColor") } }
    @Published var backgroundOpacity: Double { didSet { d.set(backgroundOpacity, forKey: "bgOpacity") } }
    @Published var backgroundBlur: Double { didSet { d.set(backgroundBlur, forKey: "bgBlur") } }
    @Published var theme: ThemeMode { didSet { d.set(theme.rawValue, forKey: "theme") } }

    // Transcription defaults
    @Published var modelsDirectory: String { didSet { d.set(modelsDirectory, forKey: "modelsDir") } }
    @Published var defaultModel: String { didSet { d.set(defaultModel, forKey: "defaultModel") } }
    @Published var spokenLanguage: String { didSet { d.set(spokenLanguage, forKey: "spokenLanguage") } }
    @Published var formats: Set<ExportFormat> { didSet { d.set(formats.map(\.rawValue), forKey: "formats") } }
    @Published var outputFolder: String { didSet { d.set(outputFolder, forKey: "outputFolder") } }
    @Published var translateToEnglish: Bool { didSet { d.set(translateToEnglish, forKey: "translate") } }
    @Published var useVAD: Bool { didSet { d.set(useVAD, forKey: "vad") } }
    @Published var maxSegmentLength: Int { didSet { d.set(maxSegmentLength, forKey: "maxLen") } }
    @Published var splitOnWord: Bool { didSet { d.set(splitOnWord, forKey: "splitOnWord") } }
    @Published var threads: Int { didSet { d.set(threads, forKey: "threads") } }
    @Published var initialPrompt: String { didSet { d.set(initialPrompt, forKey: "prompt") } }
    @Published var persianCleanup: Bool { didSet { d.set(persianCleanup, forKey: "persianCleanup") } }
    @Published var modelSource: ModelSource { didSet { d.set(modelSource.rawValue, forKey: "modelSource") } }

    // Paths
    @Published var toolOverrides: [String: String] { didSet { d.set(toolOverrides, forKey: "toolOverrides") } }

    // Network
    @Published var proxyKind: ProxyKind { didSet { d.set(proxyKind.rawValue, forKey: "proxyKind"); Network.shared.rebuild() } }
    @Published var proxyHost: String { didSet { d.set(proxyHost, forKey: "proxyHost"); Network.shared.rebuild() } }
    @Published var proxyPort: Int { didSet { d.set(proxyPort, forKey: "proxyPort"); Network.shared.rebuild() } }

    // Speech
    @Published var ttsVoice: String { didSet { d.set(ttsVoice, forKey: "ttsVoice") } }
    @Published var ttsRate: Double { didSet { d.set(ttsRate, forKey: "ttsRate") } }
    @Published var finishSound: String { didSet { d.set(finishSound, forKey: "finishSound") } }

    private init() {
        uiLanguage = d.string(forKey: "uiLanguage") ?? (Locale.preferredLanguages.first?.hasPrefix("fa") == true ? "fa" : "en")
        showMenuBarIcon = d.object(forKey: "showMenuBarIcon") as? Bool ?? true
        keepAwakeWhileWorking = d.object(forKey: "keepAwake") as? Bool ?? true
        onboarded = d.bool(forKey: "onboarded")
        watchFolders = d.stringArray(forKey: "watchFolders") ?? []

        backgroundMode = BackgroundMode(rawValue: d.string(forKey: "bgMode") ?? "") ?? (Self.hasLiquidGlass ? .glass : .translucent)
        backgroundColorHex = d.string(forKey: "bgColor") ?? "#1E1B2E"
        backgroundOpacity = d.object(forKey: "bgOpacity") as? Double ?? 0.82
        backgroundBlur = d.object(forKey: "bgBlur") as? Double ?? 24
        theme = ThemeMode(rawValue: d.string(forKey: "theme") ?? "") ?? .system

        modelsDirectory = d.string(forKey: "modelsDir") ?? (NSHomeDirectory() + "/.cache/whisper-cpp-models")
        defaultModel = d.string(forKey: "defaultModel") ?? "ggml-large-v3-turbo-q5_0.bin"
        spokenLanguage = d.string(forKey: "spokenLanguage") ?? "auto"
        formats = Set((d.stringArray(forKey: "formats") ?? ["txt", "srt"]).compactMap(ExportFormat.init(rawValue:)))
        outputFolder = d.string(forKey: "outputFolder") ?? ""
        translateToEnglish = d.bool(forKey: "translate")
        useVAD = d.bool(forKey: "vad")
        maxSegmentLength = d.integer(forKey: "maxLen")
        splitOnWord = d.bool(forKey: "splitOnWord")
        threads = d.object(forKey: "threads") as? Int ?? min(8, ProcessInfo.processInfo.activeProcessorCount)
        initialPrompt = d.string(forKey: "prompt") ?? ""
        persianCleanup = d.object(forKey: "persianCleanup") as? Bool ?? true
        modelSource = ModelSource(rawValue: d.string(forKey: "modelSource") ?? "") ?? .huggingface

        toolOverrides = d.dictionary(forKey: "toolOverrides") as? [String: String] ?? [:]

        proxyKind = ProxyKind(rawValue: d.string(forKey: "proxyKind") ?? "") ?? .none
        proxyHost = d.string(forKey: "proxyHost") ?? "127.0.0.1"
        proxyPort = d.object(forKey: "proxyPort") as? Int ?? 1080

        ttsVoice = d.string(forKey: "ttsVoice") ?? ""
        ttsRate = d.object(forKey: "ttsRate") as? Double ?? 1.0
        finishSound = d.string(forKey: "finishSound") ?? "Glass"
    }

    static var hasLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var backgroundColor: NSColor { NSColor(hex: backgroundColorHex) ?? .windowBackgroundColor }

    var modelsURL: URL { URL(fileURLWithPath: (modelsDirectory as NSString).expandingTildeInPath, isDirectory: true) }

    var defaultModelURL: URL? {
        let url = modelsURL.appendingPathComponent(defaultModel)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: modelsURL.path)) ?? []
        return files.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") && !$0.contains("silero") }.sorted().last.map { modelsURL.appendingPathComponent($0) }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    var isDark: Bool {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.5
    }
}

enum Paths {
    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hush", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func folder(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var temp: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Hush", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
