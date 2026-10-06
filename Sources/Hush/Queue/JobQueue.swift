import AppKit
import Foundation
import HushCore

@MainActor
final class JobQueue: ObservableObject {
    static let shared = JobQueue()

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published var finishActions: FinishActions {
        didSet { UserDefaults.standard.set(finishActions.rawValue, forKey: "finishActions") }
    }
    @Published var notifyEachJob: Bool {
        didSet { UserDefaults.standard.set(notifyEachJob, forKey: "notifyEachJob") }
    }

    private var engine: WhisperEngine?
    private var converter: ProcessRunner?
    private var current: UUID?
    private var startedBatch = 0
    private let store = Paths.support.appendingPathComponent("queue.json")

    private init() {
        finishActions = FinishActions(rawValue: UserDefaults.standard.integer(forKey: "finishActions"))
        notifyEachJob = UserDefaults.standard.object(forKey: "notifyEachJob") as? Bool ?? true
        restore()
    }

    // MARK: - Overview

    var pending: [Job] { jobs.filter { !$0.state.isFinished } }
    var activeJob: Job? { jobs.first { $0.id == current } }

    /// Progress of the whole batch, 0…1.
    var overallProgress: Double {
        let batch = jobs.filter { $0.state != .cancelled }
        guard !batch.isEmpty else { return 0 }
        let done = batch.reduce(0.0) { $0 + ($1.state.isFinished ? 1 : $1.progress) }
        return done / Double(batch.count)
    }

    // MARK: - Editing

    func add(_ urls: [URL], options: TranscribeOptions = .fromSettings(), delivery: TelegramDelivery? = nil, start: Bool = true) {
        let files = urls.flatMap(expand).filter(Media.isSupported)
        for url in files where !jobs.contains(where: { $0.source == url && !$0.state.isFinished }) {
            jobs.append(Job(source: url, options: options, delivery: delivery))
        }
        persist()
        if start { self.start() }
    }

    /// Uses the options on screen for everything not started yet (they may have changed after the files were dropped).
    func reapply(options: TranscribeOptions, delivery: TelegramDelivery?) {
        for i in jobs.indices where jobs[i].state == .waiting && !jobs[i].fromBot {
            jobs[i].options = options
            jobs[i].delivery = delivery
        }
        persist()
    }

    /// Bot jobs go before everything that hasn't started yet.
    func addUrgent(_ job: Job) {
        let index = jobs.firstIndex { $0.state == .waiting } ?? jobs.endIndex
        jobs.insert(job, at: index)
        persist()
        start()
    }

    private func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [url] }
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return (items?.allObjects as? [URL] ?? []).sorted { $0.path < $1.path }
    }

    func remove(_ id: UUID) {
        if id == current { cancel(id) }
        jobs.removeAll { $0.id == id }
        persist()
    }

    func move(_ id: UUID, by offset: Int) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(jobs.count - 1, i + offset))
        guard i != j else { return }
        jobs.swapAt(i, j)
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        jobs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    func retry(_ id: UUID) {
        update(id) { $0.state = .waiting; $0.progress = 0 }
        start()
    }

    func cancel(_ id: UUID) {
        if id == current {
            engine?.cancel()
            converter?.cancel()
        }
        update(id) { if !$0.state.isFinished { $0.state = .cancelled } }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
        persist()
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            engine?.pause()
            converter?.pause()
            if let current { update(current) { $0.state = .paused } }
        } else {
            engine?.resume()
            converter?.resume()
            if let current { update(current) { $0.state = .transcribing } }
            start()
        }
    }

    func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        Dock.update()
    }

    // MARK: - Running

    func start() {
        guard !isRunning, !isPaused else { return }
        guard jobs.contains(where: { $0.state == .waiting }) else { return }
        isRunning = true
        startedBatch = jobs.filter { $0.state == .waiting }.count
        if AppSettings.shared.keepAwakeWhileWorking { Awake.shared.begin() }
        Task { await loop() }
    }

    private func loop() async {
        var completed = 0, failed = 0
        while !isPaused, let next = jobs.first(where: { $0.state == .waiting }) {
            await process(next.id)
            if let job = jobs.first(where: { $0.id == next.id }) {
                if job.state == .done { completed += 1 }
                if case .failed = job.state { failed += 1 }
                if notifyEachJob, !job.fromBot, job.state.isFinished, pending.count > 0 {
                    Notifier.post(title: job.title, body: job.state.title)
                }
            }
        }
        isRunning = false
        current = nil
        Awake.shared.end()
        Dock.update()
        persist()
        if !isPaused, completed + failed > 0, !jobs.contains(where: { $0.state == .waiting }) {
            let summary = failed == 0 ? L("%d job(s) finished.", completed) : L("%d job(s) finished, %d failed.", completed, failed)
            let onlyBot = jobs.filter { $0.finished.map { Date().timeIntervalSince($0) < 86_400 } ?? false }.allSatisfy(\.fromBot)
            if !onlyBot { FinishRunner.run(finishActions, summary: summary) }
        }
    }

    private func process(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        current = id
        update(id) { $0.state = .preparing; $0.started = Date(); $0.progress = 0 }
        var wav: URL?
        defer {
            if let wav { try? FileManager.default.removeItem(at: wav) }
            persist()
        }
        do {
            let info = try await Media.probe(job.source)
            update(id) { $0.duration = info.duration }
            guard info.hasAudio else { throw MediaError.failed(L("This file has no audio track.")) }
            let audio = try await Media.toWhisperWAV(job.source) { [weak self] runner in self?.converter = runner }
            wav = audio
            converter = nil
            if jobs.first(where: { $0.id == id })?.state == .cancelled { return }
            update(id) { $0.state = .transcribing }
            let engine = WhisperEngine()
            self.engine = engine
            let result = try await engine.transcribe(wav: audio, options: job.options) { value in
                Task { @MainActor in JobQueue.shared.update(id) { $0.progress = value } }
            }
            self.engine = nil
            update(id) { $0.state = .saving }
            var record = TranscriptRecord(id: UUID(), title: job.title, sourcePath: job.source.path, created: Date(),
                                          language: result.language ?? job.options.language, model: job.options.model,
                                          duration: info.duration, segments: result.segments, outputs: [])
            if !job.fromBot {
                let folder = OutputWriter.folder(for: job.source, preferred: job.options.outputFolder)
                let urls = try OutputWriter.write(record, formats: job.options.formats, to: folder)
                record.outputs = urls.map(\.path)
                update(id) { $0.outputs = urls }
            }
            if !job.temporarySource { History.shared.save(record) }
            update(id) { $0.recordID = record.id }
            if let delivery = job.delivery {
                update(id) { $0.state = .sending }
                try await TelegramBot.shared.deliver(record: record, source: job.source, duration: info.duration, delivery: delivery)
            }
            update(id) { $0.state = .done; $0.progress = 1; $0.finished = Date() }
        } catch is CancellationError {
            update(id) { $0.state = .cancelled; $0.finished = Date() }
        } catch {
            let message = error.localizedDescription
            update(id) {
                if $0.state != .cancelled { $0.state = .failed(message) }
                $0.finished = Date()
            }
            if let delivery = job.delivery, job.fromBot {
                TelegramBot.shared.reportFailure(message, delivery: delivery)
            }
        }
        if job.temporarySource { try? FileManager.default.removeItem(at: job.source) }
    }

    // MARK: - Persistence (a quit mid-run resumes next launch)

    private func persist() {
        let keep = jobs.filter { !$0.temporarySource }
        if let data = try? JSONEncoder().encode(keep) { try? data.write(to: store, options: .atomic) }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: store), let saved = try? JSONDecoder().decode([Job].self, from: data) else { return }
        jobs = saved.map { job in
            var j = job
            if j.state.isActive || j.state == .paused { j.state = .waiting; j.progress = 0 }
            return j
        }
    }

    func resumeAfterLaunch() {
        if jobs.contains(where: { $0.state == .waiting }) { start() }
    }
}
