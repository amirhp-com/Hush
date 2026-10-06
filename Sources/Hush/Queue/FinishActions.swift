import AppKit
import Foundation

struct FinishActions: OptionSet, Codable, Hashable {
    let rawValue: Int
    static let notify = FinishActions(rawValue: 1 << 0)
    static let sound = FinishActions(rawValue: 1 << 1)
    static let telegram = FinishActions(rawValue: 1 << 2)
    static let quit = FinishActions(rawValue: 1 << 3)
    static let sleep = FinishActions(rawValue: 1 << 4)
    static let shutdown = FinishActions(rawValue: 1 << 5)

    static let all: [(FinishActions, String, String)] = [
        (.notify, "bell", "Show a notification"),
        (.sound, "speaker.wave.2", "Play a sound"),
        (.telegram, "paperplane", "Message me on Telegram"),
        (.quit, "xmark.circle", "Quit Hush"),
        (.sleep, "moon.zzz", "Put the Mac to sleep"),
        (.shutdown, "power", "Shut down the Mac")
    ]
}

@MainActor
enum FinishRunner {
    static func run(_ actions: FinishActions, summary: String) {
        if actions.contains(.notify) { Notifier.post(title: "Hush", body: summary) }
        if actions.contains(.sound) { NSSound(named: AppSettings.shared.finishSound)?.play() }
        if actions.contains(.telegram) { TelegramBot.shared.notifyOwner("✅ " + summary) }
        if actions.contains(.shutdown) {
            countdown(L("The Mac will shut down"), action: { Power.shutdown() })
        } else if actions.contains(.sleep) {
            countdown(L("The Mac will go to sleep"), action: { Power.sleep() })
        } else if actions.contains(.quit) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
    }

    /// Gives the user 30 seconds to cancel a shutdown or sleep.
    private static func countdown(_ message: String, action: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = L("All jobs are finished. This happens automatically in 30 seconds.")
        alert.addButton(withTitle: L("Do it now"))
        alert.addButton(withTitle: L("Cancel"))
        var cancelled = false
        let timer = Timer(timeInterval: 30, repeats: false) { _ in
            NSApp.abortModal()
        }
        RunLoop.main.add(timer, forMode: .common)
        let response = alert.runModal()
        timer.invalidate()
        if response == .alertSecondButtonReturn { cancelled = true }
        if !cancelled { action() }
    }
}

enum Power {
    static func sleep() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        try? p.run()
    }

    static func shutdown() {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to shut down")?.executeAndReturnError(&error)
        if error != nil {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"System Events\" to shut down"]
            try? p.run()
        }
    }
}
