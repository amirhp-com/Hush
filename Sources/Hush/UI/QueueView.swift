import HushCore
import SwiftUI

struct QueueView: View {
    @ObservedObject private var queue = JobQueue.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            if queue.jobs.isEmpty {
                ContentUnavailableView(L("The queue is empty"), systemImage: "list.bullet.rectangle",
                                       description: Text(L("Drop files anywhere in this window to add them.")))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(queue.jobs) { job in
                        JobRow(job: job).listRowSeparator(.hidden)
                    }
                    .onMove { queue.move(fromOffsets: $0, toOffset: $1) }
                }
                .scrollContentBackground(.hidden)
            }
            finishBar
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Queue")).font(.largeTitle.weight(.semibold))
                Spacer()
                Button(action: FilePicker.addToQueue) { Label(L("Add Files…"), systemImage: "plus") }
                Button(L("Clear Finished")) { queue.clearFinished() }.disabled(!queue.jobs.contains { $0.state.isFinished })
                if queue.isRunning || queue.isPaused {
                    Button { queue.togglePause() } label: {
                        Label(queue.isPaused ? L("Resume") : L("Pause"), systemImage: queue.isPaused ? "play.fill" : "pause.fill")
                    }
                } else {
                    Button { queue.start() } label: { Label(L("Start"), systemImage: "play.fill") }
                        .compatGlassButton(prominent: true)
                        .disabled(!queue.jobs.contains { $0.state == .waiting })
                }
            }
            if queue.isRunning || queue.isPaused {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: queue.overallProgress)
                    Text(L("%d of %d done", queue.jobs.filter { $0.state.isFinished }.count, queue.jobs.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
    }

    private var finishBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("When everything is done")).font(.headline)
            FlowLayout(spacing: 8) {
                ForEach(FinishActions.all, id: \.0.rawValue) { action, symbol, title in
                    Toggle(isOn: Binding(get: { queue.finishActions.contains(action) },
                                         set: { on in
                                             if on { queue.finishActions.insert(action) } else { queue.finishActions.remove(action) }
                                             if on, action == .shutdown { queue.finishActions.remove(.sleep) }
                                             if on, action == .sleep { queue.finishActions.remove(.shutdown) }
                                         })) {
                        Label(L(title), systemImage: symbol)
                    }
                    .toggleStyle(.button)
                }
            }
            Toggle(L("Notify me after each job"), isOn: $queue.notifyEachJob).font(.caption)
            if queue.finishActions.contains(.sound) { SoundPicker() }
        }
        .padding(16)
        .glassCard()
        .padding([.horizontal, .bottom], 16)
    }
}

struct SoundPicker: View {
    @ObservedObject private var settings = AppSettings.shared
    static let sounds = ["Glass", "Hero", "Ping", "Purr", "Submarine", "Funk", "Blow", "Bottle", "Frog", "Pop", "Sosumi", "Tink", "Basso", "Morse"]

    var body: some View {
        HStack {
            Picker(L("Sound"), selection: $settings.finishSound) {
                ForEach(Self.sounds, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 220)
            Button { NSSound(named: settings.finishSound)?.play() } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless)
        }
        .font(.caption)
    }
}

struct JobRow: View {
    let job: Job
    @ObservedObject private var queue = JobQueue.shared

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(job.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if job.fromBot { Image(systemName: "paperplane.fill").font(.caption).foregroundStyle(.blue).help("Telegram") }
                    if job.delivery != nil, !job.fromBot { Image(systemName: "paperplane").font(.caption).foregroundStyle(.secondary) }
                }
                if job.state.isActive || job.state == .paused { ProgressView(value: job.progress) }
                HStack(spacing: 8) {
                    Text(job.state.title).foregroundStyle(stateColor).lineLimit(2)
                    if job.duration > 0 { Text(TimeFormat.short(job.duration)) }
                    Text(SpokenLanguage.name(job.options.language))
                    if let eta = job.eta { Text(L("About %@ left", TimeFormat.short(eta))) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(12)
        .glassCard(cornerRadius: 12)
    }

    private var icon: some View {
        Image(systemName: Media.isVideo(job.source) ? "film" : "waveform")
            .font(.title3)
            .frame(width: 38, height: 38)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.15)))
    }

    private var stateColor: Color {
        switch job.state {
        case .done: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            switch job.state {
            case .done:
                if let id = job.recordID {
                    Button(L("Open")) { Router.shared.openRecord = id; Router.shared.tab = .history }
                }
                if let first = job.outputs.first {
                    Button { NSWorkspace.shared.activateFileViewerSelecting(job.outputs.isEmpty ? [first] : job.outputs) } label: { Image(systemName: "folder") }
                        .help(L("Show in Finder"))
                }
            case .failed, .cancelled:
                Button(L("Retry")) { queue.retry(job.id) }
            case .waiting:
                Button { queue.move(job.id, by: -1) } label: { Image(systemName: "arrow.up") }.help(L("Move up"))
                Button { queue.move(job.id, by: 1) } label: { Image(systemName: "arrow.down") }.help(L("Move down"))
            default:
                Button(L("Cancel"), role: .destructive) { queue.cancel(job.id) }
            }
            Button { queue.remove(job.id) } label: { Image(systemName: "xmark") }.help(L("Remove"))
        }
        .buttonStyle(.borderless)
    }
}
