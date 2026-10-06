import HushCore
import SwiftUI
import UniformTypeIdentifiers

struct SpeakView: View {
    @ObservedObject private var speech = Speech.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var tools = ToolManager.shared
    @ObservedObject private var telegram = TelegramStore.shared
    @State private var text = ""
    @State private var output: URL?
    @State private var working = false
    @State private var status: String?
    @State private var format: Media.AudioFormat = .m4a

    private var voice: Voice? { speech.voice(id: settings.ttsVoice) ?? speech.bestVoice(for: text) }

    var body: some View {
        Page(title: L("Speak"), subtitle: L("Type or paste text and Hush reads it aloud. Save it as audio or send it to Telegram.")) {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $text)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .environment(\.layoutDirection, Exporter.isRightToLeft(text) ? .rightToLeft : .leftToRight)
                    .frame(minHeight: 200)
                    .padding(10)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty { Text(L("Text to read aloud…")).foregroundStyle(.tertiary).padding(16).allowsHitTesting(false) }
                    }
                HStack {
                    Button(L("Open text file…"), action: openText).buttonStyle(.borderless)
                    Spacer()
                    Text(L("%d characters", text.count)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .glassCard()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker(L("Voice"), selection: $settings.ttsVoice) {
                        Text(L("Automatic (by the text's language)")).tag("")
                        if !speech.piperVoices.isEmpty {
                            Section("Piper") { ForEach(speech.piperVoices) { Text("\($0.name) · \($0.language)").tag($0.id) } }
                        }
                        Section(L("macOS voices")) { ForEach(speech.systemVoices) { Text("\($0.name) · \($0.language)").tag($0.id) } }
                    }
                    .frame(maxWidth: 380)
                    SettingsLink { Text(L("Get Persian voices…")) }
                        .simultaneousGesture(TapGesture().onEnded { SettingsRouter.shared.tab = .voices })
                }
                HStack {
                    Text(L("Speed"))
                    Slider(value: $settings.ttsRate, in: 0.5...1.8).frame(maxWidth: 220)
                    Text(String(format: "%.1f×", settings.ttsRate)).monospacedDigit().foregroundStyle(.secondary)
                }
                if Exporter.isRightToLeft(text) && speech.piperVoices.first(where: { $0.language.hasPrefix("fa") }) == nil {
                    Label(L("macOS has no Persian voice. Install Piper and a Persian voice in Settings → Voices."), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(16)
            .glassCard()

            HStack(spacing: 10) {
                Button { Task { await make(play: true) } } label: { Label(L("Play"), systemImage: "play.fill") }
                    .compatGlassButton(prominent: true)
                Button { speech.stop() } label: { Label(L("Stop"), systemImage: "stop.fill") }
                Picker("", selection: $format) { ForEach(Media.AudioFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) } }
                    .labelsHidden().frame(width: 90)
                Button { Task { await save() } } label: { Label(L("Save Audio…"), systemImage: "square.and.arrow.down") }
                if !telegram.allowedChats.isEmpty {
                    Button { Task { await sendTelegram() } } label: { Label(L("Send as voice"), systemImage: "paperplane") }
                }
                if working { ProgressView().controlSize(.small) }
                Spacer()
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @discardableResult
    private func make(play: Bool) async -> URL? {
        guard let voice else { status = L("No voice is available."); return nil }
        working = true
        defer { working = false }
        do {
            let url = try await speech.synthesize(text, voice: voice, rate: settings.ttsRate)
            output = url
            if play { speech.play(url) }
            status = nil
            return url
        } catch {
            status = error.localizedDescription
            return nil
        }
    }

    private func save() async {
        guard let audio = await make(play: false) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(text.prefix(30)).replacingOccurrences(of: "/", with: "-") + "." + format.rawValue
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            _ = try await Media.convertAudio(audio, to: format, destination: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            status = error.localizedDescription
        }
    }

    private func sendTelegram() async {
        guard let audio = await make(play: false) else { return }
        working = true
        defer { working = false }
        do {
            try await TelegramBot.shared.sendAudioFile(audio, title: String(text.prefix(40)), chat: telegram.defaultChat, asVoice: true)
            status = L("Sent")
        } catch {
            status = error.localizedDescription
        }
    }

    private func openText() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        if panel.runModal() == .OK, let url = panel.url, let s = try? String(contentsOf: url, encoding: .utf8) { text = s }
    }
}

struct LiveView: View {
    @ObservedObject private var live = LiveDictation.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Page(title: L("Live"), subtitle: L("Speak into the microphone and the text appears as you talk. Everything stays on this Mac.")) {
            HStack(spacing: 16) {
                Button { live.toggle() } label: {
                    Image(systemName: live.isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(Circle().fill(live.isListening ? Color.red : Color.accentColor))
                        .overlay(Circle().stroke(Color.accentColor.opacity(0.35), lineWidth: 6).scaleEffect(1 + CGFloat(live.level) * 0.6))
                        .animation(.easeOut(duration: 0.15), value: live.level)
                }
                .buttonStyle(.plain)
                .disabled(live.isStarting)
                VStack(alignment: .leading, spacing: 6) {
                    Text(live.isStarting ? L("Loading the model…") : live.isListening ? L("Listening…") : L("Click to start"))
                        .font(.title3.weight(.medium))
                    Picker(L("Language"), selection: $settings.spokenLanguage) {
                        ForEach(SpokenLanguage.all, id: \.code) { Text(SpokenLanguage.name($0.code)).tag($0.code) }
                    }
                    .frame(maxWidth: 260)
                    .disabled(live.isListening)
                }
                if live.isStarting { ProgressView() }
            }
            if let error = live.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            TextEditor(text: $live.text)
                .font(.title3)
                .scrollContentBackground(.hidden)
                .environment(\.layoutDirection, Exporter.isRightToLeft(live.text) ? .rightToLeft : .leftToRight)
                .frame(minHeight: 260)
                .padding(10)
                .glassCard()
            HStack {
                Button(L("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(live.text, forType: .string)
                }
                Button(L("Save as Text…")) {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = L("Dictation") + ".txt"
                    if panel.runModal() == .OK, let url = panel.url { try? live.text.write(to: url, atomically: true, encoding: .utf8) }
                }
                Button(L("Clear"), role: .destructive) { live.text = "" }
                Spacer()
            }
            .disabled(live.text.isEmpty)
        }
    }
}
