import HushCore
import ServiceManagement
import SwiftUI

final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var tab: SettingsTab = .general
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, models, voices, tools, network
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return L("General")
        case .appearance: return L("Appearance")
        case .models: return L("Models")
        case .voices: return L("Voices")
        case .tools: return L("Tools")
        case .network: return L("Network")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .models: return "cpu"
        case .voices: return "person.wave.2"
        case .tools: return "wrench.and.screwdriver"
        case .network: return "network"
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        TabView(selection: $router.tab) {
            ForEach(SettingsTab.allCases) { tab in
                content(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noFocusRing()
    }

    @ViewBuilder private func content(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .models: ModelsSettings()
        case .voices: VoicesSettings()
        case .tools: ToolsSettings()
        case .network: NetworkSettings()
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker(L("Language"), selection: $settings.uiLanguage) {
                    Text("English").tag("en")
                    Text("فارسی").tag("fa")
                }
                .pickerStyle(.segmented)
                Toggle(L("Launch Hush at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle(L("Show Hush in the menu bar"), isOn: $settings.showMenuBarIcon)
                Toggle(L("Keep the Mac awake while transcribing"), isOn: $settings.keepAwakeWhileWorking)
            }
            Section {
                ForEach(settings.watchFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { settings.watchFolders.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button(L("Add Watch Folder…")) {
                    if let url = FilePicker.chooseFolder(message: L("New audio and video files in this folder are transcribed automatically.")),
                       !settings.watchFolders.contains(url.path) { settings.watchFolders.append(url.path) }
                }
            } header: {
                Text(L("Watch folders"))
            } footer: {
                Text(L("Files dropped into these folders are added to the queue automatically.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Finder")) {
                Text(L("Right-click audio or video files in Finder and choose Services → Transcribe with Hush. You can also drop files on the Hush icon in the Dock."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

struct AppearanceSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker(L("Background"), selection: $settings.backgroundMode) {
                    ForEach(BackgroundMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                if settings.backgroundMode == .glass && !AppSettings.hasLiquidGlass {
                    Text(L("Liquid Glass needs macOS 26 or later. Translucent is used instead.")).font(.caption).foregroundStyle(.orange)
                }
                ColorPicker(L("Color"), selection: Binding(
                    get: { Color(nsColor: settings.backgroundColor) },
                    set: { settings.backgroundColorHex = NSColor($0).hexString }), supportsOpacity: false)
                if settings.backgroundMode != .solid {
                    LabeledContent(L("Opacity")) {
                        HStack {
                            Slider(value: $settings.backgroundOpacity, in: 0.1...1)
                            Text("\(Int(settings.backgroundOpacity * 100))%").monospacedDigit().frame(width: 44)
                        }
                    }
                }
                if settings.backgroundMode == .translucent {
                    LabeledContent(L("Blur")) {
                        HStack {
                            Slider(value: $settings.backgroundBlur, in: 0...60)
                            Text("\(Int(settings.backgroundBlur))").monospacedDigit().frame(width: 44)
                        }
                    }
                    .disabled(!BlurRadius.isAvailable)
                }
                HStack(spacing: 8) {
                    ForEach(["#1E1B2E", "#0F172A", "#111111", "#1F2A44", "#2D1B3D", "#F5F5F7", "#FFFFFF", "#E8F0FE"], id: \.self) { hex in
                        Button { settings.backgroundColorHex = hex } label: {
                            Circle().fill(Color(nsColor: NSColor(hex: hex) ?? .gray)).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.primary.opacity(settings.backgroundColorHex == hex ? 0.9 : 0.15), lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text(L("Window"))
            } footer: {
                Text(L("Like Terminal: pick a color, then choose how much of the desktop shows through.")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker(L("Theme"), selection: $settings.theme) {
                    ForEach(ThemeMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

struct ModelsSettings: View {
    @ObservedObject private var store = ModelStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showAll = false

    private var visible: [WhisperModel] {
        showAll ? store.available : store.available.filter { !$0.englishOnly && !$0.isDiarize && ($0.quantized == nil || $0.quantized == "q5_0" || $0.quantized == "q8_0") }
    }

    var body: some View {
        Form {
            Section {
                ForEach(visible) { model in ModelRow(model: model) }
                Toggle(L("Show every variant (English-only, other compressions)"), isOn: $showAll).font(.caption)
            } header: {
                HStack {
                    Text(L("Speech models"))
                    Spacer()
                    if store.loading { ProgressView().controlSize(.small) }
                    Button(L("Refresh")) { Task { await store.refreshCatalog() } }.buttonStyle(.borderless)
                }
            } footer: {
                Text(L("“large-v3-turbo-q5_0” is the best balance for Persian. Smaller models are faster but make more mistakes."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Voice activity detection")) {
                HStack {
                    Text("Silero VAD")
                    Spacer()
                    if store.hasVADModel { Label(L("Installed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else if let p = store.downloads[WhisperEngine.vadModelFile] { ProgressView(value: p.fraction).frame(width: 120) }
                    else { Button(L("Download")) { store.download(WhisperEngine.vadModelFile) } }
                }
            }
            Section(L("Storage")) {
                LabeledContent(L("Folder")) {
                    HStack {
                        Text((settings.modelsDirectory as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Button(L("Change…")) {
                            if let url = FilePicker.chooseFolder(message: L("Choose where speech models are kept")) {
                                settings.modelsDirectory = url.path
                                store.scanInstalled()
                            }
                        }
                        Button { NSWorkspace.shared.open(settings.modelsURL) } label: { Image(systemName: "folder") }.buttonStyle(.borderless)
                    }
                }
                Picker(L("Download from"), selection: $settings.modelSource) {
                    ForEach(ModelSource.allCases) { Text($0.title).tag($0) }
                }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { await store.refreshCatalog() }
    }
}

struct ModelRow: View {
    let model: WhisperModel
    @ObservedObject private var store = ModelStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).font(.body.weight(.medium))
                    if model.isRecommended { Text(L("Recommended")).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.accentColor.opacity(0.2))) }
                    if settings.defaultModel == model.file { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                }
                HStack(spacing: 10) {
                    Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))
                    Meter(label: L("Speed"), value: model.speed)
                    Meter(label: L("Accuracy"), value: model.accuracy)
                    if model.englishOnly { Text(L("English only")) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = store.downloads[model.file] {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: p.fraction).frame(width: 120)
                    Text("\(ByteCountFormatter.string(fromByteCount: p.written, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: p.total, countStyle: .file))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button { store.cancel(model.file) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
            } else if store.isInstalled(model.file) {
                if settings.defaultModel != model.file { Button(L("Use")) { settings.defaultModel = model.file } }
                Button(role: .destructive) { store.delete(model.file) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            } else {
                Button(L("Download")) { store.download(model.file) }
            }
        }
    }
}

private struct Meter: View {
    let label: String
    let value: Int
    var body: some View {
        HStack(spacing: 2) {
            Text(label)
            ForEach(1...5, id: \.self) { i in
                Capsule().fill(i <= value ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width: 6, height: 6)
            }
        }
    }
}

struct VoicesSettings: View {
    @ObservedObject private var speech = Speech.shared
    @ObservedObject private var tools = ToolManager.shared
    @State private var filter = "fa"

    private var languages: [String] { Array(Set(speech.piperCatalog.map { String($0.language.prefix(2)) })).sorted() }

    var body: some View {
        Form {
            if tools.piper == nil {
                Section {
                    Label(L("Piper isn't installed. Install it in the Tools tab to use these natural voices."), systemImage: "info.circle")
                    Button(L("Install Piper")) { Task { await tools.install(.piper) } }.disabled(tools.busy != nil)
                    if tools.busy == .piper { ProgressView().controlSize(.small) }
                }
            }
            Section {
                Picker(L("Language"), selection: $filter) {
                    Text(L("All")).tag("")
                    ForEach(languages, id: \.self) { Text($0 == "fa" ? "فارسی" : $0).tag($0) }
                }
                ForEach(speech.piperCatalog.filter { filter.isEmpty || $0.language.hasPrefix(filter) }) { voice in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(voice.name) · \(voice.quality)").font(.body.weight(.medium))
                            Text("\(voice.language) · \(voice.languageName) · \(ByteCountFormatter.string(fromByteCount: voice.bytes, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let p = speech.downloading[voice.key] {
                            ProgressView(value: p).frame(width: 100)
                            Button { speech.cancelDownload(voice.key) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                        } else if speech.installedPiper.contains(voice.key) {
                            Label(L("Installed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.iconOnly)
                            Button(role: .destructive) { speech.deletePiper(voice.key) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        } else {
                            Button(L("Download")) { speech.download(voice) }
                        }
                    }
                }
            } header: {
                Text(L("Piper voices"))
            } footer: {
                Text(L("Voices come from rhasspy/piper-voices on Hugging Face. Each voice has its own license; see its model card.")).font(.caption).foregroundStyle(.secondary)
            }
            if let error = speech.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { if speech.piperCatalog.isEmpty { await speech.refreshPiperCatalog() } }
    }
}

struct ToolsSettings: View {
    @ObservedObject private var tools = ToolManager.shared

    var body: some View {
        Form {
            Section {
                ForEach(Tool.allCases) { tool in ToolRow(tool: tool) }
            } header: {
                HStack {
                    Text(L("Command-line tools"))
                    Spacer()
                    Button(L("Refresh")) { Task { await tools.refresh() } }.buttonStyle(.borderless)
                }
            } footer: {
                Text(L("Hush uses these free tools. They are installed and updated with Homebrew, the standard package manager for macOS."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !tools.log.isEmpty {
                Section(L("Log")) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(tools.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).id("end")
                                .environment(\.layoutDirection, .leftToRight)
                        }
                        .frame(height: 160)
                        .onChange(of: tools.log) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { await tools.refresh() }
    }
}

private struct ToolRow: View {
    let tool: Tool
    @ObservedObject private var tools = ToolManager.shared

    var body: some View {
        let status = tools.status[tool] ?? ToolStatus()
        HStack(spacing: 12) {
            Image(systemName: status.installed ? "checkmark.circle.fill" : (tool.required ? "exclamationmark.circle.fill" : "circle.dashed"))
                .foregroundStyle(status.installed ? .green : (tool.required ? .orange : .secondary))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(tool.title).font(.body.weight(.medium))
                    if let v = status.version { Text(v).font(.caption).foregroundStyle(.secondary) }
                    if !tool.required { Text(L("optional")).font(.caption2).foregroundStyle(.secondary) }
                }
                Text(tool.purpose).font(.caption).foregroundStyle(.secondary)
                if let path = status.path { Text(path).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
            }
            Spacer()
            if tools.busy == tool {
                ProgressView().controlSize(.small)
            } else if !status.installed {
                Button(L("Install")) { Task { await tools.install(tool) } }
                    .compatGlassButton(prominent: true)
                    .disabled(tools.busy != nil || (tool != .homebrew && tool != .piper && tools.brew == nil))
            } else if status.outdated || tool == .piper || tool == .whisper || tool == .ffmpeg {
                Button(status.outdated ? L("Update") : L("Check for Update")) { Task { await tools.install(tool, update: true) } }
                    .disabled(tools.busy != nil)
            }
        }
    }
}

struct NetworkSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var port = ""

    var body: some View {
        Form {
            Section {
                Picker(L("Proxy"), selection: $settings.proxyKind) {
                    ForEach(ProxyKind.allCases) { Text($0.title).tag($0) }
                }
                if settings.proxyKind != .none {
                    TextField(L("Host"), text: $settings.proxyHost)
                    TextField(L("Port"), text: $port)
                        .onAppear { port = String(settings.proxyPort) }
                        .onSubmit { if let p = Int(port) { settings.proxyPort = p } }
                        .onChange(of: port) { _, v in if let p = Int(v) { settings.proxyPort = p } }
                }
            } header: {
                Text(L("Proxy"))
            } footer: {
                Text(L("Used for downloading models and voices, for Telegram and for update checks. Transcription itself never goes online."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
