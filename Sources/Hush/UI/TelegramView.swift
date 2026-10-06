import SwiftUI

struct TelegramView: View {
    @ObservedObject private var bot = TelegramBot.shared
    @ObservedObject private var store = TelegramStore.shared
    @State private var token = TokenStore.read()
    @State private var reveal = false
    @State private var newChatID = ""
    @State private var testResult: String?

    var body: some View {
        Page(title: "Telegram", subtitle: L("Send results to Telegram, and let this Mac answer voice messages with text.")) {
            connection
            if store.allowedChats.isEmpty { gettingStarted } else { chats }
            delivery
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Bot")).font(.headline)
            HStack {
                Group {
                    if reveal { TextField("", text: $token, prompt: Text("123456789:AAH…")) } else { SecureField("", text: $token, prompt: Text("123456789:AAH…")) }
                }
                .textFieldStyle(.roundedBorder)
                Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                Button(L("Save & Connect")) {
                    TokenStore.save(token)
                    store.botEnabled = true
                    bot.start()
                }
                .compatGlassButton(prominent: true)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Toggle(L("Answer voice messages (the Mac works as the bot's server while Hush is open)"), isOn: Binding(
                get: { store.botEnabled },
                set: { on in store.botEnabled = on; on ? bot.start() : bot.stop() }))
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                if case .failed = bot.state { Button(L("Retry")) { bot.start() }.buttonStyle(.borderless).font(.caption) }
                Spacer()
                Link(L("Create a bot with @BotFather"), destination: URL(string: "https://t.me/BotFather")!).font(.caption)
            }
            Text(L("Telegram lets bots download files up to 20 MB and upload up to 50 MB. Longer audio is split into parts automatically."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .glassCard()
    }

    private var statusColor: Color {
        switch bot.state {
        case .running: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .stopped: return .gray
        }
    }

    private var statusText: String {
        switch bot.state {
        case .running(let name): return L("Connected as %@", name)
        case .connecting: return L("Connecting…")
        case .failed(let m): return m
        case .stopped: return L("Not running")
        }
    }

    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Pair your Telegram")).font(.headline)
            Step(n: 1, text: L("Create a bot with @BotFather and paste its token above."), done: bot.hasToken)
            Step(n: 2, text: L("Open your bot in Telegram and send /start."), done: false) {
                if let name = bot.botUsername { Link(L("Open @%@", name), destination: URL(string: "https://t.me/\(name)?start=pair")!) }
            }
            Step(n: 3, text: L("Click “Allow” here on the Mac."), done: false)
        }
        .padding(16)
        .glassCard()
    }

    private var chats: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Paired chats")).font(.headline)
                Spacer()
                if bot.isPairingOpen && !store.allowedChats.isEmpty {
                    Label(L("Pairing is open"), systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green).font(.caption)
                    Button(L("Close")) { bot.closePairing() }.buttonStyle(.borderless).font(.caption)
                } else {
                    Button(L("Pair another chat")) { bot.openPairing() }
                        .help(L("Opens pairing for 5 minutes. Then send /start from the other chat."))
                }
            }
            ForEach(store.allowedChats) { chat in
                HStack(spacing: 12) {
                    Image(systemName: chat.symbol).foregroundStyle(.white)
                        .frame(width: 32, height: 32).background(Circle().fill(chat.isPrivate ? Color.blue : Color.green))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.displayName).font(.body.weight(.medium))
                        Text([chat.username.map { "@\($0)" }, chat.kind, String(chat.id)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.defaultChat == chat.id {
                        Text(L("Default")).font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    } else {
                        Button(L("Make default")) { store.defaultChat = chat.id }.buttonStyle(.borderless).font(.caption)
                    }
                    Button(role: .destructive) { store.remove(chat.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            HStack {
                TextField(L("Add by chat ID"), text: $newChatID).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Button(L("Add")) {
                    guard let id = Int64(newChatID.trimmingCharacters(in: .whitespaces)) else { return }
                    store.upsert(ChatInfo(id: id, type: id > 0 ? "private" : "unknown"))
                    bot.lookUp(id)
                    newChatID = ""
                }
                Spacer()
                Button(L("Send test message")) { Task { testResult = await bot.testMessage() ?? L("Sent") } }
                if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(16)
        .glassCard()
    }

    private var delivery: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Sending results")).font(.headline)
            Text(L("Used when you choose “Also send the result to Telegram” on the Transcribe page.")).font(.caption).foregroundStyle(.secondary)
            Toggle(L("Send the audio (extracted from videos)"), isOn: $store.sendAudio)
            Picker(L("Send the text"), selection: $store.textMode) {
                ForEach(TelegramDelivery.TextMode.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 420)
            Text(L("Captions are limited to 1024 characters. Longer text is sent as a separate message instead."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .glassCard()
    }
}

private struct Step<Accessory: View>: View {
    let n: Int
    let text: String
    let done: Bool
    @ViewBuilder var accessory: () -> Accessory

    init(n: Int, text: String, done: Bool, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.n = n; self.text = text; self.done = done; self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.2)).frame(width: 24, height: 24)
                if done { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } else { Text("\(n)").font(.caption.bold()) }
            }
            Text(text)
            Spacer()
            accessory()
        }
    }
}
