import AppKit
import SwiftUI
import UserNotifications

@main
struct HushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var loc = Loc.shared

    var body: some Scene {
        Window("Hush", id: "main") {
            MainView()
                .localized()
                .frame(minWidth: 820, minHeight: 560)
                .onOpenURL { AppDelegate.openFiles([$0]) }
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 980, height: 680)
        .commands { HushCommands() }

        Settings {
            SettingsView()
                .localized()
        }

        MenuBarExtra(isInserted: Binding(get: { settings.showMenuBarIcon },
                                         set: { if $0 != settings.showMenuBarIcon { settings.showMenuBarIcon = $0 } })) {
            MenuBarView().localized()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

extension View {
    /// Applies the in-app language (with right-to-left layout for Persian) and the theme.
    func localized() -> some View { modifier(LocalizedRoot()) }
}

private struct LocalizedRoot: ViewModifier {
    @ObservedObject private var loc = Loc.shared
    @ObservedObject private var settings = AppSettings.shared

    func body(content: Content) -> some View {
        content
            .environment(\.layoutDirection, loc.direction)
            .environment(\.locale, loc.locale)
            .preferredColorScheme(settings.theme.scheme)
            .id(loc.language)
    }
}

final class Router: ObservableObject {
    static let shared = Router()
    @Published var tab: MainTab = .transcribe
    @Published var openRecord: UUID?
}

struct HushCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("Add Files…")) { FilePicker.addToQueue() }.keyboardShortcut("o")
            Button(L("Start Queue")) { Task { @MainActor in JobQueue.shared.start() } }.keyboardShortcut(.return, modifiers: .command)
        }
        CommandMenu(L("Go")) {
            ForEach(Array(MainTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.title) { Router.shared.tab = tab; openWindow(id: "main") }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServiceProvider()
        NSUpdateDynamicServices()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: "ALLOW", title: L("Allow"), options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "DENY", title: L("Deny"), options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: "PAIR", actions: [allow, deny], intentIdentifiers: [])])
        Notifier.requestPermission()

        Task { @MainActor in
            await ToolManager.shared.refresh()
            JobQueue.shared.resumeAfterLaunch()
            TelegramBot.shared.startIfEnabled()
            WatchFolders.shared.restart()
            Updater.shared.startAutomaticChecks()
            Dock.update()
            if !AppSettings.shared.onboarded { Router.shared.tab = .transcribe; OnboardingState.shared.show = true }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) { Self.openFiles(urls) }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        Self.openFiles(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    static func openFiles(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        Task { @MainActor in
            JobQueue.shared.add(files)
            Router.shared.tab = .queue
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { for w in NSApp.windows where w.identifier?.rawValue == "main" { w.makeKeyAndOrderFront(nil) } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in WhisperServer.shared.stop() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let chat = (response.notification.request.content.userInfo["chat"] as? NSNumber)?.int64Value else { return }
        await MainActor.run {
            switch response.actionIdentifier {
            case "ALLOW": TelegramBot.shared.answer(chat, allow: true)
            case "DENY": TelegramBot.shared.answer(chat, allow: false)
            default:
                Router.shared.tab = .telegram
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// Finder → Services → "Transcribe with Hush".
final class ServiceProvider: NSObject {
    @objc func transcribeFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        Task { @MainActor in
            JobQueue.shared.add(urls)
            Router.shared.tab = .queue
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@MainActor
enum FilePicker {
    static func addToQueue() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = Media.contentTypes
        panel.message = L("Choose audio or video files, or a folder")
        if panel.runModal() == .OK {
            JobQueue.shared.add(panel.urls, start: false)
            Router.shared.tab = .transcribe
        }
    }

    static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}
