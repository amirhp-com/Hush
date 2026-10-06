import AppKit
import Foundation
import HushCore
import UserNotifications

struct PairingRequest: Identifiable, Equatable {
    var chat: ChatInfo
    var date = Date()
    var id: Int64 { chat.id }
}

/// Telegram Bot API over long polling. The Mac is the server: paired chats send voice,
/// audio or video and get the transcript back. Pairing follows KeepMeUp: the first /start
/// is approved on the Mac, after that pairing stays closed until reopened for 5 minutes.
@MainActor
final class TelegramBot: ObservableObject {
    static let shared = TelegramBot()

    enum State: Equatable {
        case stopped, connecting, running(String), failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var botUsername: String?
    @Published private(set) var pairingOpenUntil: Date?
    @Published private(set) var requests: [PairingRequest] = []

    private var task: Task<Void, Never>?
    private var token = ""
    private var offset: Int64 = 0
    private let store = TelegramStore.shared

    static let uploadLimit: Int64 = 49 * 1024 * 1024
    static let downloadLimit: Int64 = 20 * 1024 * 1024

    private init() {
        NotificationCenter.default.addObserver(forName: .networkChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let bot = TelegramBot.shared
                if bot.store.botEnabled, bot.state != .stopped { bot.start() }
            }
        }
    }

    var isRunning: Bool { if case .running = state { return true } else { return false } }
    var hasToken: Bool { !TokenStore.read().isEmpty }

    var isPairingOpen: Bool {
        if store.allowedChats.isEmpty { return true }
        guard let pairingOpenUntil else { return false }
        return pairingOpenUntil > Date()
    }

    func openPairing(minutes: Double = 5) { pairingOpenUntil = Date().addingTimeInterval(minutes * 60) }
    func closePairing() { pairingOpenUntil = nil }

    // MARK: - Lifecycle

    func startIfEnabled() { if store.botEnabled { start() } }

    func start() {
        stop()
        token = TokenStore.read()
        guard !token.isEmpty else { state = .failed(L("Add a bot token first.")); return }
        state = .connecting
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        state = .stopped
    }

    /// Sending works even with the bot (polling) turned off, as long as a token exists.
    private func ensureToken() -> Bool {
        if token.isEmpty { token = TokenStore.read() }
        return !token.isEmpty
    }

    private func run() async {
        var failures = 0
        var registered = false
        while !Task.isCancelled {
            do {
                if !registered {
                    let me = try await call("getMe", [:])
                    botUsername = me["username"] as? String
                    state = .running(botUsername.map { "@\($0)" } ?? "bot")
                    try? await registerProfile()
                    try? await registerCommands()
                    await refreshChats()
                    registered = true
                }
                let result = try await call("getUpdates", ["offset": offset, "timeout": 50, "allowed_updates": ["message"]], long: true)
                if failures > 0 {
                    failures = 0
                    state = .running(botUsername.map { "@\($0)" } ?? "bot")
                }
                for update in result["result"] as? [[String: Any]] ?? [] {
                    if let id = (update["update_id"] as? NSNumber)?.int64Value { offset = id + 1 }
                    if let message = update["message"] as? [String: Any] {
                        Task { await self.handle(message) }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                if case BotError.unauthorized(let text) = error { state = .failed(text); return }
                failures += 1
                state = .failed(redact(error.localizedDescription))
                try? await Task.sleep(nanoseconds: UInt64(min(30, pow(2, Double(min(failures, 5)))) * 1_000_000_000))
            }
        }
    }

    private func refreshChats() async {
        for chat in store.allowedChats {
            if let result = try? await call("getChat", ["chat_id": chat.id]), let info = ChatInfo(telegram: result) { store.upsert(info) }
        }
    }

    func lookUp(_ id: Int64) {
        Task {
            guard ensureToken(), let result = try? await call("getChat", ["chat_id": id]), let info = ChatInfo(telegram: result) else { return }
            store.upsert(info)
        }
    }

    private func isAuthorized(_ chat: ChatInfo, sender: Int64) -> Bool {
        if chat.isPrivate { return chat.id == sender && store.isAllowed(chat.id) }
        if chat.isGroup { return store.isAllowed(chat.id) && store.isPairedUser(sender) }
        return false
    }

    // MARK: - Incoming

    private func handle(_ message: [String: Any]) async {
        guard let rawChat = message["chat"] as? [String: Any], let chat = ChatInfo(telegram: rawChat),
              chat.isPrivate || chat.isGroup,
              let from = message["from"] as? [String: Any], let sender = (from["id"] as? NSNumber)?.int64Value,
              from["is_bot"] as? Bool != true else { return }
        if chat.isPrivate && sender != chat.id { return }
        let messageID = (message["message_id"] as? NSNumber)?.int64Value
        let allowed = isAuthorized(chat, sender: sender)

        if let media = Self.media(in: message) {
            guard allowed else {
                if chat.isPrivate { try? await send(L("🔒 This chat isn't paired yet. Send /start and approve it on your Mac."), to: chat.id) }
                return
            }
            await receive(media, chat: chat, replyTo: messageID)
            return
        }

        guard let text = message["text"] as? String, text.hasPrefix("/") else {
            if allowed, chat.isPrivate, message["text"] != nil {
                try? await send(L("Send me a voice message, audio or video and I'll reply with the text. /help shows everything I can do."), to: chat.id)
            }
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? trimmed
        let parts = head.split(separator: "@", maxSplits: 1).map(String.init)
        if parts.count == 2, let me = botUsername, parts[1].lowercased() != me.lowercased() { return }
        let command = parts[0].lowercased()
        let argument = String(trimmed.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)

        if command == "/start" || command == "/pair" {
            if allowed {
                try? await send(L("✅ This chat is already paired with %@.", Host.current().localizedName ?? "Mac") + "\n\n" + helpText(), to: chat.id)
            } else if chat.isGroup && !store.isPairedUser(sender) {
                try? await send(L("🔒 Pair with me in a private chat first, then send /pair here."), to: chat.id)
            } else {
                await requestPairing(chat)
            }
            return
        }
        guard allowed else {
            if chat.isPrivate { try? await send(L("🔒 This chat isn't paired yet. Send /start and approve it on your Mac."), to: chat.id) }
            return
        }
        await execute(command, argument: argument, chat: chat, replyTo: messageID)
    }

    private func execute(_ command: String, argument: String, chat: ChatInfo, replyTo: Int64?) async {
        var p = store.prefs(for: chat.id)
        switch command {
        case "/help":
            try? await send(helpText(), to: chat.id)
        case "/lang":
            let code = argument.lowercased()
            if SpokenLanguage.all.contains(where: { $0.code == code }) {
                p.language = code
                store.setPrefs(p, for: chat.id)
                try? await send(L("🗣 Spoken language: %@", SpokenLanguage.name(code)), to: chat.id)
            } else {
                try? await send(L("Usage: /lang auto, /lang fa or /lang en. Now: %@", SpokenLanguage.name(p.language)), to: chat.id)
            }
        case "/format":
            if let f = ChatPrefs.Format(rawValue: argument.lowercased()) {
                p.format = f
                store.setPrefs(p, for: chat.id)
                try? await send(L("📄 Replies will be sent as: %@", f.rawValue), to: chat.id)
            } else {
                try? await send(L("Usage: /format text, /format srt or /format both. Now: %@", p.format.rawValue), to: chat.id)
            }
        case "/status":
            let q = JobQueue.shared
            var lines = [L("💻 %@", Host.current().localizedName ?? "Mac"), L("📋 Jobs waiting: %d", q.pending.count)]
            if let active = q.activeJob { lines.append(L("⏳ Now: %@ (%d%%)", active.title, Int(active.progress * 100))) }
            lines.append(L("🧠 Model: %@", AppSettings.shared.defaultModel))
            try? await send(lines.joined(separator: "\n"), to: chat.id)
        case "/tts":
            guard !argument.isEmpty else {
                try? await send(L("Usage: /tts followed by the text to read aloud."), to: chat.id)
                return
            }
            _ = try? await call("sendChatAction", ["chat_id": chat.id, "action": "record_voice"])
            do {
                let audio = try await Speech.shared.synthesizeForTelegram(argument)
                defer { try? FileManager.default.removeItem(at: audio) }
                try await upload(audio, method: "sendVoice", field: "voice", mime: "audio/ogg", chatID: chat.id, extra: replyFields(replyTo))
            } catch {
                try? await send(L("⚠️ Couldn't make the audio: %@", error.localizedDescription), to: chat.id)
            }
        default:
            try? await send(helpText(), to: chat.id)
        }
    }

    func helpText() -> String {
        L("""
        🎙 Send a voice message, audio file, video or video note and I'll reply with the text.

        /lang auto|fa|en — the spoken language
        /format text|srt|both — how the text comes back
        /tts <text> — read text aloud as a voice message
        /status — what the Mac is working on
        /help — this message
        """)
    }

    private struct IncomingMedia {
        var fileID: String
        var size: Int64
        var name: String
    }

    private static func media(in message: [String: Any]) -> IncomingMedia? {
        let stamp = Int(Date().timeIntervalSince1970)
        let candidates: [(String, String)] = [("voice", "voice-\(stamp).ogg"), ("audio", "audio-\(stamp).mp3"), ("video", "video-\(stamp).mp4"), ("video_note", "round-\(stamp).mp4"), ("document", "file-\(stamp)")]
        for (key, fallback) in candidates {
            guard let item = message[key] as? [String: Any], let id = item["file_id"] as? String else { continue }
            var name = item["file_name"] as? String ?? fallback
            if key == "document" {
                let mime = item["mime_type"] as? String ?? ""
                let ext = (name as NSString).pathExtension.lowercased()
                guard mime.hasPrefix("audio/") || mime.hasPrefix("video/") || Media.allExtensions.contains(ext) else { return nil }
                if ext.isEmpty { name += mime.hasPrefix("video/") ? ".mp4" : ".ogg" }
            }
            return IncomingMedia(fileID: id, size: (item["file_size"] as? NSNumber)?.int64Value ?? 0, name: name)
        }
        return nil
    }

    private func receive(_ media: IncomingMedia, chat: ChatInfo, replyTo: Int64?) async {
        guard media.size <= Self.downloadLimit else {
            try? await send(L("⚠️ Telegram lets bots download files up to 20 MB, and this one is bigger. Send a shorter clip or a compressed version."), to: chat.id)
            return
        }
        _ = try? await call("sendChatAction", ["chat_id": chat.id, "action": "typing"])
        do {
            let info = try await call("getFile", ["file_id": media.fileID])
            guard let path = info["file_path"] as? String, let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(path)") else {
                throw BotError.message(L("Telegram didn't return the file."))
            }
            let (location, _) = try await Network.shared.session.download(from: url)
            let folder = Paths.temp.appendingPathComponent("telegram", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(UUID().uuidString.prefix(6) + "-" + (media.name as NSString).lastPathComponent)
            try FileManager.default.moveItem(at: location, to: target)

            let p = store.prefs(for: chat.id)
            var options = TranscribeOptions.fromSettings()
            options.language = p.language == "auto" ? AppSettings.shared.spokenLanguage : p.language
            options.formats = []
            let mode: TelegramDelivery.TextMode = p.format == .srt ? .srtFile : .message
            var delivery = TelegramDelivery(chatID: chat.id, sendAudio: false, textMode: mode, replyTo: replyTo)
            if p.format == .both { delivery.textMode = .message }
            var job = Job(source: target, options: options, delivery: delivery, fromBot: true, temporarySource: true)
            job.title = (media.name as NSString).deletingPathExtension
            if p.format == .both { job.options.formats = [.srt] }
            let ahead = JobQueue.shared.jobs.filter { !$0.state.isFinished && $0.fromBot }.count + (JobQueue.shared.isRunning ? 1 : 0)
            JobQueue.shared.addUrgent(job)
            let note = ahead > 0 ? L("⏳ Got it. %d job(s) ahead of this one.", ahead) : L("⏳ Got it, transcribing…")
            try? await send(note, to: chat.id, replyTo: replyTo)
        } catch {
            try? await send(L("⚠️ Couldn't get that file: %@", redact(error.localizedDescription)), to: chat.id)
        }
    }

    // MARK: - Pairing (non-blocking: requests wait in the app until you answer)

    private func requestPairing(_ chat: ChatInfo) async {
        guard isPairingOpen else {
            try? await send(L("🔒 Pairing is closed. On your Mac open Hush → Telegram and click “Pair another chat”, then send /start again."), to: chat.id)
            return
        }
        if !requests.contains(where: { $0.chat.id == chat.id }) { requests.append(PairingRequest(chat: chat)) }
        try? await send(L("👋 Hi! One last step: look at your Mac and click “Allow” in Hush."), to: chat.id)
        Notifier.post(title: L("Telegram pairing request"), body: L("%@ wants to use Hush on this Mac.", chat.displayName),
                      id: "pair-\(chat.id)", category: "PAIR", userInfo: ["chat": NSNumber(value: chat.id)])
        NSApp.requestUserAttention(.criticalRequest)
    }

    func answer(_ chatID: Int64, allow: Bool) {
        guard let request = requests.first(where: { $0.chat.id == chatID }) else { return }
        requests.removeAll { $0.chat.id == chatID }
        Task {
            if allow {
                store.upsert(request.chat)
                pairingOpenUntil = nil
                try? await registerCommands()
                try? await send(L("✅ Paired with %@!", Host.current().localizedName ?? "Mac") + "\n\n" + helpText(), to: chatID)
            } else {
                try? await send(L("❌ Pairing was denied on the Mac."), to: chatID)
            }
        }
    }

    // MARK: - Outgoing

    func notifyOwner(_ text: String) {
        guard ensureToken() else { return }
        let targets = store.defaultChat != 0 ? [store.defaultChat] : store.allowedChats.filter(\.isPrivate).map(\.id)
        for chat in targets { Task { try? await send(text, to: chat) } }
    }

    func reportFailure(_ message: String, delivery: TelegramDelivery) {
        Task { try? await send(L("⚠️ Transcription failed: %@", message), to: delivery.chatID, replyTo: delivery.replyTo) }
    }

    /// Sends a finished transcript (and optionally the audio) to a chat.
    func deliver(record: TranscriptRecord, source: URL, duration: Double, delivery: TelegramDelivery) async throws {
        guard ensureToken() else { throw BotError.message(L("Add a bot token first.")) }
        let chat = delivery.chatID
        let text = record.text.isEmpty ? L("(No speech was found.)") : record.text
        var captionUsed = false
        if delivery.sendAudio {
            _ = try? await call("sendChatAction", ["chat_id": chat, "action": "upload_voice"])
            let ogg = try await Media.convertAudio(source, to: .ogg, bitrate: duration > 3 * 3600 ? "24k" : "48k")
            defer { try? FileManager.default.removeItem(at: ogg) }
            let parts = try await Media.splitForUpload(ogg, maxBytes: Self.uploadLimit, duration: duration)
            for (i, part) in parts.enumerated() {
                var extra = replyFields(delivery.replyTo)
                extra["title"] = parts.count > 1 ? "\(record.title) (\(i + 1)/\(parts.count))" : record.title
                if i == 0, delivery.textMode == .caption, TextChunker.fitsCaption(text) {
                    extra["caption"] = text
                    captionUsed = true
                }
                try await upload(part, method: "sendAudio", field: "audio", mime: "audio/ogg", chatID: chat, extra: extra)
            }
        }
        switch delivery.textMode {
        case .none: break
        case .caption where captionUsed: break
        case .caption, .message:
            for (i, chunk) in TextChunker.split(text, limit: 4000).enumerated() {
                try await send(chunk, to: chat, replyTo: i == 0 ? delivery.replyTo : nil)
            }
        case .txtFile, .srtFile:
            let format: ExportFormat = delivery.textMode == .srtFile ? .srt : .txt
            try await sendTranscriptFile(record, format: format, chat: chat, replyTo: delivery.replyTo)
        }
        if delivery.textMode == .message, JobQueue.shared.jobs.contains(where: { $0.recordID == record.id && $0.options.formats.contains(.srt) }) {
            try await sendTranscriptFile(record, format: .srt, chat: chat, replyTo: nil)
        }
    }

    func sendTranscriptFile(_ record: TranscriptRecord, format: ExportFormat, chat: Int64, replyTo: Int64?) async throws {
        let file = Paths.temp.appendingPathComponent(record.title + "." + format.fileExtension)
        try OutputWriter.write(record, format: format, to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await upload(file, method: "sendDocument", field: "document", mime: "application/octet-stream", chatID: chat, extra: replyFields(replyTo))
    }

    func sendAudioFile(_ file: URL, title: String, chat: Int64, asVoice: Bool) async throws {
        guard ensureToken() else { throw BotError.message(L("Add a bot token first.")) }
        let ogg = try await Media.convertAudio(file, to: .ogg)
        defer { try? FileManager.default.removeItem(at: ogg) }
        try await upload(ogg, method: asVoice ? "sendVoice" : "sendAudio", field: asVoice ? "voice" : "audio", mime: "audio/ogg", chatID: chat, extra: ["title": title])
    }

    func sendText(_ text: String, chat: Int64) async throws {
        guard ensureToken() else { throw BotError.message(L("Add a bot token first.")) }
        for chunk in TextChunker.split(text, limit: 4000) { try await send(chunk, to: chat) }
    }

    func testMessage() async -> String? {
        guard ensureToken() else { return L("Add a bot token first.") }
        guard store.defaultChat != 0 else { return L("Pair a chat first.") }
        do {
            try await send(L("👋 Test message from Hush on %@.", Host.current().localizedName ?? "Mac"), to: store.defaultChat)
            return nil
        } catch {
            return redact(error.localizedDescription)
        }
    }

    private func replyFields(_ replyTo: Int64?) -> [String: String] {
        guard let replyTo else { return [:] }
        return ["reply_parameters": "{\"message_id\":\(replyTo),\"allow_sending_without_reply\":true}"]
    }

    private func registerProfile() async throws {
        _ = try await call("setMyDescription", ["description": L("Hush turns voice messages, audio and video into text on its owner's Mac.\n\nTap Start, then approve the request on the Mac.")])
        _ = try await call("setMyShortDescription", ["short_description": L("Voice to text, powered by Hush on a Mac.")])
    }

    private func registerCommands() async throws {
        let commands = [("help", L("What I can do")), ("lang", L("Spoken language: auto, fa or en")), ("format", L("Reply as text, srt or both")),
                        ("tts", L("Read text aloud")), ("status", L("What the Mac is working on"))].map { ["command": $0.0, "description": $0.1] }
        _ = try await call("setMyCommands", ["commands": [["command": "start", "description": L("Pair this chat with the Mac")]]])
        for chat in store.allowedChats where chat.isPrivate || chat.isGroup {
            _ = try? await call("setMyCommands", ["commands": commands, "scope": ["type": "chat", "chat_id": chat.id]])
        }
    }

    // MARK: - HTTP

    private func send(_ text: String, to chat: Int64, replyTo: Int64? = nil) async throws {
        var params: [String: Any] = ["chat_id": chat, "text": text]
        if let replyTo { params["reply_parameters"] = ["message_id": replyTo, "allow_sending_without_reply": true] }
        try await call("sendMessage", params)
    }

    @discardableResult
    private func call(_ method: String, _ params: [String: Any], long: Bool = false) async throws -> [String: Any] {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { throw BotError.message("Bad token") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: params)
        let (data, _) = try await (long ? Network.shared.longSession : Network.shared.session).data(for: request)
        return try decode(data)
    }

    private func upload(_ file: URL, method: String, field: String, mime: String, chatID: Int64, extra: [String: String] = [:]) async throws {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { throw BotError.message("Bad token") }
        let boundary = "Hush-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("chat_id", String(chatID))
        for (k, v) in extra { field(k, v) }
        let filename = file.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let (data, _) = try await Network.shared.session.data(for: request)
        _ = try decode(data)
    }

    private func redact(_ text: String) -> String {
        token.isEmpty ? text : text.replacingOccurrences(of: token, with: "•••")
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BotError.message("Unexpected response") }
        guard json["ok"] as? Bool == true else {
            if (json["error_code"] as? NSNumber)?.intValue == 401 {
                throw BotError.unauthorized(L("The bot token was rejected. Check it in the Telegram tab."))
            }
            throw BotError.message(json["description"] as? String ?? "Telegram error")
        }
        if let result = json["result"] as? [String: Any] { return result }
        return json
    }

    enum BotError: LocalizedError {
        case message(String), unauthorized(String)
        var errorDescription: String? {
            switch self { case .message(let t), .unauthorized(let t): return t }
        }
    }
}
