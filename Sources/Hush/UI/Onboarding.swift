import HushCore
import SwiftUI

final class OnboardingState: ObservableObject {
    static let shared = OnboardingState()
    @Published var show = false
}

struct OnboardingView: View {
    @ObservedObject private var tools = ToolManager.shared
    @ObservedObject private var models = ModelStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var state = OnboardingState.shared

    private let recommended = "ggml-large-v3-turbo-q5_0.bin"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading) {
                    Text(L("Welcome to Hush")).font(.title.bold())
                    Text(L("Three quick checks and you're ready.")).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $settings.uiLanguage) {
                    Text("English").tag("en")
                    Text("فارسی").tag("fa")
                }
                .pickerStyle(.segmented).frame(width: 150)
            }

            step(1, L("Tools"), done: tools.missingRequired.isEmpty) {
                if tools.missingRequired.isEmpty {
                    Text(L("whisper.cpp and FFmpeg are installed.")).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tools.missingRequired) { tool in
                            HStack {
                                Text(tool.title)
                                Spacer()
                                if tools.busy == tool { ProgressView().controlSize(.small) }
                                else if tools.brew == nil { Button(L("Install Homebrew")) { Task { await tools.install(.homebrew) } } }
                                else { Button(L("Install")) { Task { await tools.install(tool) } } }
                            }
                        }
                        Button(L("Refresh")) { Task { await tools.refresh() } }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }

            step(2, L("Speech model"), done: !models.installed.isEmpty) {
                if !models.installed.isEmpty {
                    Text(L("Using %@.", WhisperModel(file: settings.defaultModel, bytes: 0).name)).foregroundStyle(.secondary)
                } else if let p = models.downloads[recommended] {
                    ProgressView(value: p.fraction) { Text(L("Downloading large-v3-turbo-q5_0…")) }
                } else {
                    HStack {
                        Text(L("large-v3-turbo-q5_0 (574 MB) works well for Persian and English."))
                        Spacer()
                        Button(L("Download")) { models.download(recommended) }
                    }
                }
            }

            step(3, L("Language"), done: true) {
                Picker(L("Most of my recordings are in"), selection: $settings.spokenLanguage) {
                    ForEach(SpokenLanguage.all, id: \.code) { Text(SpokenLanguage.name($0.code)).tag($0.code) }
                }
                .frame(maxWidth: 360)
            }

            HStack {
                Spacer()
                Button(L("Start using Hush")) {
                    settings.onboarded = true
                    state.show = false
                }
                .compatGlassButton(prominent: true)
                .controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 620)
        .task { await tools.refresh(); models.scanInstalled() }
    }

    private func step<C: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.2)).frame(width: 28, height: 28)
                if done { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } else { Text("\(n)").bold() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct MenuBarLabel: View {
    @ObservedObject private var queue = JobQueue.shared

    var body: some View {
        if queue.isRunning {
            Image(systemName: "waveform.circle.fill")
        } else {
            Image(systemName: "waveform")
        }
    }
}

struct MenuBarView: View {
    @ObservedObject private var queue = JobQueue.shared
    @ObservedObject private var bot = TelegramBot.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Hush").font(.headline)
                Spacer()
                Circle().fill(bot.isRunning ? Color.green : Color.gray).frame(width: 7, height: 7)
                Text(bot.isRunning ? L("Bot online") : L("Bot off")).font(.caption).foregroundStyle(.secondary)
            }
            if let job = queue.activeJob {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title).lineLimit(1)
                    ProgressView(value: job.progress)
                    Text("\(job.state.title) · " + L("%d waiting", max(0, queue.pending.count - 1))).font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .glassCard(cornerRadius: 10)
                Button(queue.isPaused ? L("Resume") : L("Pause")) { queue.togglePause() }
            } else {
                Text(queue.pending.isEmpty ? L("Nothing in the queue.") : L("%d waiting", queue.pending.count))
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button(L("Open Hush")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button(L("Add Files…")) { NSApp.activate(ignoringOtherApps: true); FilePicker.addToQueue() }
            Button(L("Live Dictation")) { Router.shared.tab = .live; openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Divider()
            Button(L("Quit Hush")) { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 280)
    }
}
