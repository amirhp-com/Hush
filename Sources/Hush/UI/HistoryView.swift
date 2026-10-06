import AVKit
import HushCore
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @ObservedObject private var history = History.shared
    @ObservedObject private var router = Router.shared
    @State private var search = ""

    private var filtered: [TranscriptRecord] {
        let q = PersianText.normalizeForSearch(search)
        guard !q.isEmpty else { return history.records }
        return history.records.filter { PersianText.normalizeForSearch($0.title + " " + $0.text).contains(q) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField(L("Search transcripts"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(12)
                List(selection: $router.openRecord) {
                    ForEach(filtered) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.title).font(.body.weight(.medium)).lineLimit(1)
                            Text(record.text.prefix(90)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text("\(record.created.formatted(date: .abbreviated, time: .shortened)) · \(TimeFormat.short(record.duration))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                        .tag(record.id)
                        .contextMenu {
                            Button(L("Delete"), role: .destructive) { history.delete(record) }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .overlay {
                    if history.records.isEmpty {
                        ContentUnavailableView(L("No transcripts yet"), systemImage: "text.bubble", description: Text(L("Finished transcripts appear here.")))
                    }
                }
            }
            .frame(minWidth: 230, idealWidth: 270, maxWidth: 360)

            Group {
                if let record = history.record(router.openRecord) {
                    TranscriptEditor(record: record).id(record.id)
                } else {
                    ContentUnavailableView(L("Choose a transcript"), systemImage: "doc.text.magnifyingglass")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct TranscriptEditor: View {
    @State var record: TranscriptRecord
    @State private var player: AVPlayer?
    @State private var current: UUID?
    @State private var find = ""
    @State private var replace = ""
    @State private var showReplace = false
    @State private var dirty = false
    @State private var message: String?
    @State private var observer: Any?
    @ObservedObject private var telegram = TelegramStore.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let player, FileManager.default.fileExists(atPath: record.sourcePath) {
                VideoPlayer(player: player)
                    .frame(height: Media.isVideo(record.sourceURL) ? 220 : 54)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
            }
            if showReplace { replaceBar }
            ScrollViewReader { proxy in
                List {
                    ForEach($record.segments) { $segment in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Button(TimeFormat.short(segment.start)) { seek(segment) }
                                .buttonStyle(.borderless)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(current == segment.id ? Color.accentColor : .secondary)
                            TextField("", text: $segment.text, axis: .vertical)
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(Exporter.isRightToLeft(segment.text) ? .trailing : .leading)
                                .environment(\.layoutDirection, Exporter.isRightToLeft(segment.text) ? .rightToLeft : .leftToRight)
                                .onChange(of: segment.text) { _, _ in dirty = true }
                                .padding(4)
                                .background(current == segment.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .id(segment.id)
                        .listRowSeparator(.hidden)
                    }
                }
                .scrollContentBackground(.hidden)
                .onChange(of: current) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        .onAppear(perform: setupPlayer)
        .onDisappear {
            if dirty { History.shared.save(record) }
            if let observer { player?.removeTimeObserver(observer) }
            player?.pause()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: $record.title).font(.title2.weight(.semibold)).textFieldStyle(.plain)
                    .onChange(of: record.title) { _, _ in dirty = true }
                Text("\(SpokenLanguage.name(record.language)) · \(record.model) · \(record.segments.count) " + L("lines"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showReplace.toggle() } label: { Image(systemName: "magnifyingglass") }.help(L("Find and replace"))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
                flash(L("Copied"))
            } label: { Image(systemName: "doc.on.doc") }.help(L("Copy all text"))
            Menu {
                ForEach(ExportFormat.allCases) { f in Button(f.title) { export(f) } }
            } label: { Label(L("Export"), systemImage: "square.and.arrow.up") }
                .fixedSize()
            if !telegram.allowedChats.isEmpty {
                Menu {
                    Button(L("Text as a message")) { send(.message, audio: false) }
                    Button(L("Text as a .txt file")) { send(.txtFile, audio: false) }
                    Button(L("Subtitles as a .srt file")) { send(.srtFile, audio: false) }
                    Divider()
                    Button(L("Audio with the text as caption")) { send(.caption, audio: true) }
                    Button(L("Audio and the text separately")) { send(.message, audio: true) }
                    Button(L("Audio only")) { send(.none, audio: true) }
                } label: { Label("Telegram", systemImage: "paperplane") }
                    .fixedSize()
            }
            if dirty {
                Button(L("Save")) { History.shared.save(record); dirty = false; flash(L("Saved")) }
                    .compatGlassButton(prominent: true)
                    .keyboardShortcut("s")
            }
        }
        .padding(16)
    }

    private var replaceBar: some View {
        HStack {
            TextField(L("Find"), text: $find).textFieldStyle(.roundedBorder)
            TextField(L("Replace with"), text: $replace).textFieldStyle(.roundedBorder)
            Button(L("Replace All")) {
                guard !find.isEmpty else { return }
                var count = 0
                for i in record.segments.indices where record.segments[i].text.contains(find) {
                    record.segments[i].text = record.segments[i].text.replacingOccurrences(of: find, with: replace)
                    count += 1
                }
                dirty = dirty || count > 0
                flash(L("%d line(s) changed", count))
            }
            Button(L("Fix Persian text")) {
                for i in record.segments.indices { record.segments[i].text = PersianText.normalize(record.segments[i].text) }
                dirty = true
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func setupPlayer() {
        guard FileManager.default.fileExists(atPath: record.sourcePath) else { return }
        let p = AVPlayer(url: record.sourceURL)
        player = p
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.3, preferredTimescale: 600), queue: .main) { time in
            let t = time.seconds
            MainActor.assumeIsolated {
                current = record.segments.last { $0.start <= t + 0.05 }?.id
            }
        }
    }

    private func seek(_ segment: Segment) {
        player?.seek(to: CMTime(seconds: segment.start, preferredTimescale: 600))
        player?.play()
        current = segment.id
    }

    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.title + format.fileSuffix + "." + format.fileExtension
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OutputWriter.write(record, format: format, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            flash(error.localizedDescription)
        }
    }

    private func send(_ mode: TelegramDelivery.TextMode, audio: Bool) {
        let delivery = TelegramDelivery(chatID: telegram.defaultChat, sendAudio: audio, textMode: mode, replyTo: nil)
        flash(L("Sending to Telegram…"))
        Task {
            do {
                try await TelegramBot.shared.deliver(record: record, source: record.sourceURL, duration: record.duration, delivery: delivery)
                flash(L("Sent"))
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    private func flash(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if message == text { message = nil } }
    }
}
