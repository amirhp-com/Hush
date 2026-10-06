import AppKit
import Foundation
import IOKit.pwr_mgt
import UserNotifications

/// Keeps the Mac awake while jobs run.
final class Awake {
    static let shared = Awake()
    private var assertion = IOPMAssertionID(0)
    private var active = false

    func begin() {
        guard !active else { return }
        active = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Hush is transcribing" as CFString, &assertion) == kIOReturnSuccess
    }

    func end() {
        guard active else { return }
        IOPMAssertionRelease(assertion)
        active = false
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, id: String = UUID().uuidString, category: String? = nil, userInfo: [String: Any] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

@MainActor
enum Dock {
    static func update() {
        let queue = JobQueue.shared
        let remaining = queue.pending.count
        NSApp.dockTile.badgeLabel = remaining > 0 ? Loc.shared.isRTL ? remaining.formatted(.number.locale(Loc.shared.locale)) : "\(remaining)" : nil
        DockProgressView.shared.progress = queue.isRunning ? queue.overallProgress : nil
    }
}

/// Draws the app icon with a progress bar in the Dock while jobs run.
final class DockProgressView: NSView {
    static let shared = DockProgressView()

    var progress: Double? {
        didSet {
            guard oldValue != progress else { return }
            if NSApp.dockTile.contentView == nil { NSApp.dockTile.contentView = self }
            NSApp.dockTile.display()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        guard let progress else { return }
        let bar = NSRect(x: bounds.width * 0.14, y: bounds.height * 0.1, width: bounds.width * 0.72, height: bounds.height * 0.09)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        var fill = bar.insetBy(dx: 2, dy: 2)
        fill.size.width = max(fill.height, fill.width * progress)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
    }
}

/// Polls watch folders and queues new media once their size stops changing.
@MainActor
final class WatchFolders {
    static let shared = WatchFolders()
    private var timer: Timer?
    private var seen: Set<String> = []
    private var sizes: [String: Int64] = [:]

    func restart() {
        timer?.invalidate()
        seen = []
        let folders = AppSettings.shared.watchFolders
        guard !folders.isEmpty else { return }
        for path in folders { for f in files(in: path) { seen.insert(f.path) } }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in WatchFolders.shared.scan() }
        }
    }

    private func files(in path: String) -> [URL] {
        let url = URL(fileURLWithPath: path)
        return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []).filter(Media.isSupported)
    }

    private func scan() {
        var ready: [URL] = []
        for path in AppSettings.shared.watchFolders {
            for f in files(in: path) where !seen.contains(f.path) {
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                if let last = sizes[f.path], last == size, size > 0 {
                    seen.insert(f.path)
                    sizes[f.path] = nil
                    ready.append(f)
                } else {
                    sizes[f.path] = size
                }
            }
        }
        if !ready.isEmpty { JobQueue.shared.add(ready) }
    }
}
