import Foundation
import HushCore

enum JobState: Codable, Equatable {
    case waiting
    case preparing
    case transcribing
    case saving
    case sending
    case paused
    case done
    case failed(String)
    case cancelled

    var isActive: Bool { [.preparing, .transcribing, .saving, .sending].contains(self) }
    var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .waiting: return L("Waiting")
        case .preparing: return L("Preparing audio…")
        case .transcribing: return L("Transcribing…")
        case .saving: return L("Saving…")
        case .sending: return L("Sending to Telegram…")
        case .paused: return L("Paused")
        case .done: return L("Done")
        case .failed(let m): return L("Failed: %@", m)
        case .cancelled: return L("Cancelled")
        }
    }
}

/// What to send to Telegram once a job is done.
struct TelegramDelivery: Codable, Equatable {
    enum TextMode: String, Codable, CaseIterable, Identifiable {
        case none, caption, message, txtFile, srtFile
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return L("Don't send the text")
            case .caption: return L("As the audio's caption")
            case .message: return L("As a separate message")
            case .txtFile: return L("As a .txt file")
            case .srtFile: return L("As a .srt file")
            }
        }
    }

    var chatID: Int64
    var sendAudio: Bool
    var textMode: TextMode
    var replyTo: Int64?
}

struct Job: Codable, Identifiable, Equatable {
    var id = UUID()
    var source: URL
    var title: String
    var options: TranscribeOptions
    var state: JobState = .waiting
    var progress: Double = 0
    var duration: Double = 0
    var added = Date()
    var started: Date?
    var finished: Date?
    var recordID: UUID?
    var outputs: [URL] = []
    var delivery: TelegramDelivery?
    var fromBot = false
    /// Delete the source when done (files downloaded from Telegram).
    var temporarySource = false

    init(source: URL, options: TranscribeOptions, delivery: TelegramDelivery? = nil, fromBot: Bool = false, temporarySource: Bool = false) {
        self.source = source
        self.title = source.deletingPathExtension().lastPathComponent
        self.options = options
        self.delivery = delivery
        self.fromBot = fromBot
        self.temporarySource = temporarySource
    }

    var eta: TimeInterval? {
        guard state == .transcribing, let started, progress > 0.03 else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        return elapsed / progress - elapsed
    }
}
