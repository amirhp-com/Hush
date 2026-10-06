import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case transcribe, queue, history, speak, live, telegram
    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcribe: return L("Transcribe")
        case .queue: return L("Queue")
        case .history: return L("History")
        case .speak: return L("Speak")
        case .live: return L("Live")
        case .telegram: return L("Telegram")
        }
    }

    var symbol: String {
        switch self {
        case .transcribe: return "waveform.badge.plus"
        case .queue: return "list.bullet.rectangle"
        case .history: return "clock.arrow.circlepath"
        case .speak: return "speaker.wave.2.bubble"
        case .live: return "mic"
        case .telegram: return "paperplane"
        }
    }
}

struct MainView: View {
    @ObservedObject private var router = Router.shared
    @ObservedObject private var queue = JobQueue.shared
    @ObservedObject private var bot = TelegramBot.shared
    @ObservedObject private var tools = ToolManager.shared
    @ObservedObject private var onboarding = OnboardingState.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { router.tab }, set: { if let t = $0 { router.tab = t } })) {
                ForEach(MainTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .badge(badge(for: tab))
                        .tag(tab)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { SidebarStatus().padding(10) }
        } detail: {
            VStack(spacing: 0) {
                if !tools.missingRequired.isEmpty { MissingToolsBanner() }
                if !bot.requests.isEmpty { PairingBanner() }
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(WindowBackground())
        .sheet(isPresented: $onboarding.show) { OnboardingView().localized() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            DropHelper.load(providers) { urls in
                queue.add(urls, start: false)
                router.tab = .transcribe
            }
            return true
        }
    }

    @ViewBuilder private var detail: some View {
        switch router.tab {
        case .transcribe: TranscribeView()
        case .queue: QueueView()
        case .history: HistoryView()
        case .speak: SpeakView()
        case .live: LiveView()
        case .telegram: TelegramView()
        }
    }

    private func badge(for tab: MainTab) -> Int {
        switch tab {
        case .queue: return queue.pending.count
        case .telegram: return bot.requests.count
        default: return 0
        }
    }
}

private struct SidebarStatus: View {
    @ObservedObject private var queue = JobQueue.shared

    var body: some View {
        if queue.isRunning, let job = queue.activeJob {
            VStack(alignment: .leading, spacing: 6) {
                Text(job.title).font(.caption.weight(.medium)).lineLimit(1)
                ProgressView(value: queue.overallProgress)
                Text(job.state.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(10)
            .glassCard(cornerRadius: 12)
        }
    }
}

private struct MissingToolsBanner: View {
    @ObservedObject private var tools = ToolManager.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(L("Some tools Hush needs aren't installed: %@", tools.missingRequired.map(\.title).joined(separator: "، ")))
                .font(.callout)
            Spacer()
            SettingsLink { Text(L("Open Tools")) }
                .simultaneousGesture(TapGesture().onEnded { SettingsRouter.shared.tab = .tools })
        }
        .padding(12)
        .glassCard(cornerRadius: 12)
        .padding([.horizontal, .top], 14)
    }
}

private struct PairingBanner: View {
    @ObservedObject private var bot = TelegramBot.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(bot.requests) { request in
                HStack(spacing: 12) {
                    Image(systemName: request.chat.symbol)
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.blue))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("%@ wants to use Hush on this Mac.", request.chat.displayName)).font(.callout.weight(.medium))
                        Text([request.chat.username.map { "@\($0)" }, request.chat.kind, String(request.chat.id)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L("Only allow this if you sent /start yourself just now.")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Deny"), role: .destructive) { bot.answer(request.chat.id, allow: false) }
                    Button(L("Allow")) { bot.answer(request.chat.id, allow: true) }.compatGlassButton(prominent: true)
                }
                .padding(12)
                .glassCard(cornerRadius: 12)
            }
        }
        .padding([.horizontal, .top], 14)
    }
}

enum DropHelper {
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion(urls.sorted { $0.path < $1.path }) } }
    }
}

/// A titled page with consistent padding.
struct Page<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.largeTitle.weight(.semibold))
                    if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
                }
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
