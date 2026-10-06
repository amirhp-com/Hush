import HushCore
import SwiftUI

struct TranscribeView: View {
    @ObservedObject private var queue = JobQueue.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var models = ModelStore.shared
    @ObservedObject private var telegram = TelegramStore.shared
    @State private var targeted = false
    @State private var showAdvanced = false
    @State private var sendToTelegram = false

    private var waiting: [Job] { queue.jobs.filter { $0.state == .waiting && !$0.fromBot } }

    var body: some View {
        Page(title: L("Transcribe"), subtitle: L("Drop audio or video files. Hush turns the speech into text, right on this Mac.")) {
            dropZone
            if !waiting.isEmpty { waitingList }
            if let job = queue.activeJob, !job.fromBot { ActiveJobCard(job: job) }
            optionsCard
            HStack {
                Spacer()
                Button {
                    queue.reapply(options: .fromSettings(), delivery: sendToTelegram ? telegram.defaultDelivery : nil)
                    queue.start()
                    if waiting.count > 1 { Router.shared.tab = .queue }
                } label: {
                    Label(waiting.count > 1 ? L("Start %d jobs", waiting.count) : L("Start"), systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 14).padding(.vertical, 4)
                }
                .compatGlassButton(prominent: true)
                .controlSize(.large)
                .disabled(waiting.isEmpty || settings.defaultModelURL == nil)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private var dropZone: some View {
        Button(action: FilePicker.addToQueue) {
            VStack(spacing: 12) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 44, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                Text(L("Drop files here or click to choose")).font(.title3.weight(.medium))
                Text(L("OGG, Opus, WAV, MP3, M4A, FLAC, MP4, MKV, MOV, WebM and more"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 38)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .glassCard(cornerRadius: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            DropHelper.load(providers) { queue.add($0, start: false) }
            return true
        }
    }

    private var waitingList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Ready to start")).font(.headline)
                Spacer()
                Button(L("Clear")) { waiting.forEach { queue.remove($0.id) } }.buttonStyle(.borderless)
            }
            ForEach(waiting) { job in
                HStack {
                    Image(systemName: Media.isVideo(job.source) ? "film" : "waveform").foregroundStyle(.secondary).frame(width: 20)
                    Text(job.source.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { queue.remove(job.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .glassCard()
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text(L("Spoken language"))
                    Picker("", selection: $settings.spokenLanguage) {
                        ForEach(SpokenLanguage.all, id: \.code) { Text(SpokenLanguage.name($0.code)).tag($0.code) }
                    }
                    .labelsHidden().frame(maxWidth: 240, alignment: .leading)
                }
                GridRow {
                    Text(L("Model"))
                    HStack {
                        if models.installed.isEmpty {
                            Text(L("No model yet")).foregroundStyle(.orange)
                        } else {
                            Picker("", selection: $settings.defaultModel) {
                                ForEach(models.installed, id: \.self) { Text(WhisperModel(file: $0, bytes: 0).name).tag($0) }
                            }
                            .labelsHidden().frame(maxWidth: 240, alignment: .leading)
                        }
                        SettingsLink { Text(L("Get more…")) }
                            .simultaneousGesture(TapGesture().onEnded { SettingsRouter.shared.tab = .models })
                    }
                }
                GridRow(alignment: .top) {
                    Text(L("Save as"))
                    FormatChips(selection: $settings.formats)
                }
                GridRow {
                    Text(L("Save to"))
                    HStack {
                        Text(settings.outputFolder.isEmpty ? L("Next to each file") : (settings.outputFolder as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button(L("Change…")) {
                            if let url = FilePicker.chooseFolder(message: L("Where should transcripts be saved?")) { settings.outputFolder = url.path }
                        }
                        if !settings.outputFolder.isEmpty { Button(L("Reset")) { settings.outputFolder = "" }.buttonStyle(.borderless) }
                    }
                }
                if !telegram.allowedChats.isEmpty {
                    GridRow {
                        Text("Telegram")
                        Toggle(L("Also send the result to %@", chatName), isOn: $sendToTelegram)
                    }
                }
            }
            DisclosureGroup(L("Advanced"), isExpanded: $showAdvanced) {
                AdvancedOptions().padding(.top, 8)
            }
        }
        .padding(16)
        .glassCard()
    }

    private var chatName: String {
        telegram.allowedChats.first { $0.id == telegram.defaultChat }?.displayName ?? L("your chat")
    }
}

struct AdvancedOptions: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var models = ModelStore.shared

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text(L("Translate"))
                Toggle(L("Translate the speech into English"), isOn: $settings.translateToEnglish)
            }
            GridRow {
                Text(L("Persian text"))
                Toggle(L("Fix Persian letters and spacing (ی، ک، نیم‌فاصله)"), isOn: $settings.persianCleanup)
            }
            GridRow {
                Text(L("Silence"))
                HStack {
                    Toggle(L("Skip silent parts (VAD)"), isOn: $settings.useVAD)
                    if settings.useVAD && !models.hasVADModel {
                        Button(L("Download VAD model")) { models.download(WhisperEngine.vadModelFile) }
                    }
                }
            }
            GridRow {
                Text(L("Line length"))
                HStack {
                    Stepper(value: $settings.maxSegmentLength, in: 0...200, step: 10) {
                        Text(settings.maxSegmentLength == 0 ? L("Automatic") : L("%d characters", settings.maxSegmentLength))
                    }
                    Toggle(L("Split on words"), isOn: $settings.splitOnWord)
                }
            }
            GridRow {
                Text(L("CPU threads"))
                Stepper(value: $settings.threads, in: 1...ProcessInfo.processInfo.activeProcessorCount) { Text("\(settings.threads)") }
            }
            GridRow(alignment: .top) {
                Text(L("Vocabulary"))
                VStack(alignment: .leading, spacing: 4) {
                    TextField(L("Names and terms to expect, e.g. Hush, whisper.cpp"), text: $settings.initialPrompt, axis: .vertical)
                        .lineLimit(1...3)
                    Text(L("Helps with the spelling of names and technical words.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct FormatChips: View {
    @Binding var selection: Set<ExportFormat>

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(ExportFormat.allCases) { format in
                let on = selection.contains(format)
                Button {
                    if on { if selection.count > 1 { selection.remove(format) } } else { selection.insert(format) }
                } label: {
                    Text(format == .timestamped ? L("TXT with times") : format.rawValue.uppercased())
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
                .help(L(format.title))
            }
        }
    }
}

struct ActiveJobCard: View {
    let job: Job
    @ObservedObject private var queue = JobQueue.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.title).font(.headline).lineLimit(1)
                Spacer()
                if let eta = job.eta { Text(L("About %@ left", TimeFormat.short(eta))).font(.caption).foregroundStyle(.secondary) }
            }
            ProgressView(value: job.progress)
            HStack {
                Text(job.state.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(queue.isPaused ? L("Resume") : L("Pause")) { queue.togglePause() }.buttonStyle(.borderless)
                Button(L("Cancel"), role: .destructive) { queue.cancel(job.id) }.buttonStyle(.borderless)
            }
        }
        .padding(16)
        .glassCard()
    }
}

/// Wraps children onto new lines when they don't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
