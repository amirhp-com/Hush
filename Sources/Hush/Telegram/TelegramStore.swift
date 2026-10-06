import Foundation

struct ChatInfo: Codable, Identifiable, Equatable, Hashable {
    var id: Int64
    var type: String
    var title: String
    var username: String?

    var isPrivate: Bool { type == "private" }
    var isGroup: Bool { type == "group" || type == "supergroup" }

    var symbol: String {
        switch type {
        case "private": return "person.fill"
        case "group", "supergroup": return "person.3.fill"
        case "channel": return "megaphone.fill"
        default: return "questionmark.bubble.fill"
        }
    }

    var kind: String {
        switch type {
        case "private": return L("Private chat")
        case "group", "supergroup": return L("Group")
        case "channel": return L("Channel")
        default: return L("Unknown chat")
        }
    }

    var displayName: String { title.isEmpty ? L("Chat %@", String(id)) : title }

    init(id: Int64, type: String = "unknown", title: String = "", username: String? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.username = username
    }

    init?(telegram chat: [String: Any]) {
        guard let id = (chat["id"] as? NSNumber)?.int64Value else { return nil }
        let name = [chat["first_name"], chat["last_name"]].compactMap { $0 as? String }.joined(separator: " ")
        let title = (chat["title"] as? String) ?? name
        self.init(id: id, type: chat["type"] as? String ?? "unknown",
                  title: String(title.filter { !$0.isNewline }.prefix(64)),
                  username: (chat["username"] as? String).map { String($0.prefix(32)) })
    }
}

/// Per-chat bot preferences, changed with /lang and /format.
struct ChatPrefs: Codable, Equatable {
    enum Format: String, Codable, CaseIterable { case text, srt, both }
    var language = "auto"
    var format = Format.text
}

/// Paired chats and bot settings (KeepMeUp's pairing model).
final class TelegramStore: ObservableObject {
    static let shared = TelegramStore()
    private let d = UserDefaults.standard

    @Published var botEnabled: Bool { didSet { d.set(botEnabled, forKey: "botEnabled") } }
    @Published var allowedChats: [ChatInfo] { didSet { save(allowedChats, "allowedChats") } }
    @Published var prefs: [String: ChatPrefs] { didSet { save(prefs, "chatPrefs") } }
    @Published var defaultChat: Int64 { didSet { d.set(defaultChat, forKey: "defaultChat") } }
    @Published var sendAudio: Bool { didSet { d.set(sendAudio, forKey: "tgSendAudio") } }
    @Published var textMode: TelegramDelivery.TextMode { didSet { d.set(textMode.rawValue, forKey: "tgTextMode") } }
    @Published var autoSendJobs: Bool { didSet { d.set(autoSendJobs, forKey: "tgAutoSend") } }

    private init() {
        botEnabled = d.bool(forKey: "botEnabled")
        allowedChats = Self.load([ChatInfo].self, "allowedChats") ?? []
        prefs = Self.load([String: ChatPrefs].self, "chatPrefs") ?? [:]
        defaultChat = (d.object(forKey: "defaultChat") as? NSNumber)?.int64Value ?? 0
        sendAudio = d.object(forKey: "tgSendAudio") as? Bool ?? false
        textMode = TelegramDelivery.TextMode(rawValue: d.string(forKey: "tgTextMode") ?? "") ?? .message
        autoSendJobs = d.bool(forKey: "tgAutoSend")
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func isAllowed(_ id: Int64) -> Bool { allowedChats.contains { $0.id == id } }
    func isPairedUser(_ id: Int64) -> Bool { allowedChats.contains { $0.id == id && $0.isPrivate } }

    func upsert(_ chat: ChatInfo) {
        if let i = allowedChats.firstIndex(where: { $0.id == chat.id }) { allowedChats[i] = chat } else { allowedChats.append(chat) }
        if defaultChat == 0, chat.isPrivate { defaultChat = chat.id }
    }

    func remove(_ id: Int64) {
        allowedChats.removeAll { $0.id == id }
        if defaultChat == id { defaultChat = allowedChats.first { $0.isPrivate }?.id ?? 0 }
    }

    func prefs(for id: Int64) -> ChatPrefs { prefs[String(id)] ?? ChatPrefs() }
    func setPrefs(_ p: ChatPrefs, for id: Int64) { prefs[String(id)] = p }

    var defaultDelivery: TelegramDelivery? {
        guard defaultChat != 0 else { return nil }
        return TelegramDelivery(chatID: defaultChat, sendAudio: sendAudio, textMode: textMode, replyTo: nil)
    }
}

/// The bot token, in a 0600 file under Application Support.
enum TokenStore {
    private static var cached: String?
    private static var file: URL { Paths.support.appendingPathComponent("bot-token") }

    static func read() -> String {
        if let cached { return cached }
        let value = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cached = value
        return value
    }

    static func save(_ value: String) {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        cached = token
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Paths.support.path)
        if token.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        fchmod(fd, 0o600)
        let bytes = Array(token.utf8)
        _ = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
    }
}
