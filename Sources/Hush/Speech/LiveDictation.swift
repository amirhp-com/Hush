import AVFoundation
import Foundation
import HushCore

/// Keeps `whisper-server` running with the model loaded, so short clips come back in about a second.
@MainActor
final class WhisperServer {
    static let shared = WhisperServer()
    private var runner: ProcessRunner?
    private(set) var port = 0
    private var model = ""
    private var language = ""

    var isRunning: Bool { runner != nil && port > 0 }

    func ensure(model: URL, language: String) async throws {
        if isRunning, self.model == model.path, self.language == language { return }
        stop()
        guard let server = ToolManager.shared.whisperServer else { throw MediaError.missingTool("whisper-server") }
        let port = Int.random(in: 49_200...49_900)
        let runner = ProcessRunner(executable: server, arguments: ["-m", model.path, "-l", language, "--host", "127.0.0.1", "--port", "\(port)", "-t", "\(AppSettings.shared.threads)"])
        self.runner = runner
        Task.detached { _ = await runner.run() }
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if let url = URL(string: "http://127.0.0.1:\(port)/"), (try? await URLSession.shared.data(from: url)) != nil {
                self.port = port
                self.model = model.path
                self.language = language
                return
            }
            if runner.cancelled { break }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        stop()
        throw MediaError.failed(L("The speech server didn't start."))
    }

    func transcribe(wav: Data) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/inference") else { throw MediaError.failed("server") }
        let boundary = "Hush-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stop() {
        runner?.cancel()
        runner = nil
        port = 0
    }
}

/// Microphone → short chunks split on pauses → local whisper-server → text.
@MainActor
final class LiveDictation: ObservableObject {
    static let shared = LiveDictation()

    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    @Published private(set) var level: Float = 0
    @Published var text = ""
    @Published var error: String?

    private let engine = AVAudioEngine()
    private var samples: [Int16] = []
    private var silentFrames = 0
    private var busy = false
    private var pendingChunks: [[Int16]] = []
    private let sampleRate = 16_000.0

    func toggle() { isListening ? stop() : start() }

    func start() {
        error = nil
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else {
                    LiveDictation.shared.error = L("Hush needs microphone access. Allow it in System Settings → Privacy & Security → Microphone.")
                    return
                }
                await LiveDictation.shared.begin()
            }
        }
    }

    private func begin() async {
        guard let model = AppSettings.shared.defaultModelURL else {
            error = L("No speech model is downloaded yet. Open Settings → Models and download one.")
            return
        }
        isStarting = true
        defer { isStarting = false }
        do {
            let lang = AppSettings.shared.spokenLanguage
            try await WhisperServer.shared.ensure(model: model, language: lang)
            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw MediaError.failed("audio format") }
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
                let ratio = 16_000.0 / inFormat.sampleRate
                guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return }
                var fed = false
                converter.convert(to: out, error: nil) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                guard let ptr = out.int16ChannelData?[0] else { return }
                let chunk = Array(UnsafeBufferPointer(start: ptr, count: Int(out.frameLength)))
                Task { @MainActor in LiveDictation.shared.consume(chunk) }
            }
            try engine.start()
            isListening = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isListening = false
        level = 0
        flush()
    }

    private func consume(_ chunk: [Int16]) {
        guard isListening else { return }
        samples += chunk
        let rms = sqrt(chunk.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, chunk.count)))
        level = Float(min(1, rms / 6000))
        silentFrames = rms < 500 ? silentFrames + chunk.count : 0
        let seconds = Double(samples.count) / sampleRate
        if (seconds > 2 && Double(silentFrames) / sampleRate > 0.7) || seconds > 12 { flush() }
    }

    private func flush() {
        let chunk = samples
        samples = []
        silentFrames = 0
        let voiced = chunk.contains { abs(Int($0)) > 1200 }
        guard chunk.count > Int(sampleRate * 0.6), voiced else { return }
        pendingChunks.append(chunk)
        drain()
    }

    private func drain() {
        guard !busy, !pendingChunks.isEmpty else { return }
        busy = true
        let chunk = pendingChunks.removeFirst()
        Task {
            do {
                let piece = try await WhisperServer.shared.transcribe(wav: Self.wav(chunk, rate: Int(sampleRate)))
                let clean = piece.replacingOccurrences(of: #"\[[A-Z_ ]+\]|\([^)]*\)"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty {
                    let value = AppSettings.shared.persianCleanup && Exporter.isRightToLeft(clean) ? PersianText.normalize(clean) : clean
                    text += (text.isEmpty ? "" : " ") + value
                }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
            drain()
        }
    }

    static func wav(_ samples: [Int16], rate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        d.append(Data("RIFF".utf8)); u32(36 + bytes); d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}
