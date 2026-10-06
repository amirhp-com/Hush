import SwiftUI

struct Credit: Identifiable {
    var name: String
    var role: String
    var license: String
    var url: String
    var id: String { name }

    static let all: [Credit] = [
        Credit(name: "whisper.cpp", role: "Speech recognition engine (whisper-cli, whisper-server) by Georgi Gerganov and ggml-org", license: "MIT", url: "https://github.com/ggml-org/whisper.cpp"),
        Credit(name: "OpenAI Whisper", role: "The speech recognition models", license: "MIT", url: "https://github.com/openai/whisper"),
        Credit(name: "FFmpeg", role: "Reading and converting audio and video", license: "LGPL / GPL", url: "https://ffmpeg.org"),
        Credit(name: "Piper", role: "Natural text-to-speech voices, by the Open Home Foundation", license: "GPL-3.0", url: "https://github.com/OHF-Voice/piper1-gpl"),
        Credit(name: "Piper voices", role: "Voice models, including Persian; each voice has its own license", license: "Per voice", url: "https://huggingface.co/rhasspy/piper-voices"),
        Credit(name: "Silero VAD", role: "Detecting speech and silence", license: "MIT", url: "https://github.com/snakers4/silero-vad"),
        Credit(name: "Homebrew", role: "Installing and updating the tools", license: "BSD-2-Clause", url: "https://brew.sh"),
        Credit(name: "Telegram Bot API", role: "Sending results and the voice-to-text bot", license: "Telegram terms", url: "https://core.telegram.org/bots/api"),
        Credit(name: "Hugging Face", role: "Hosting the models and voices", license: "", url: "https://huggingface.co")
    ]
}

struct AboutView: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Hush").font(.title).bold()
                Text(L("Version %@", updater.currentVersion)).foregroundStyle(.secondary)
                Text(L("Free and open source. Everything to text, right on your Mac."))
                    .multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    Link("AmirhpCom", destination: URL(string: "https://amirhp.com")!)
                    Link("GitHub", destination: URL(string: "https://github.com/amirhp-com/Hush")!)
                }
                .noFocusRing()

                UpdatePanel().padding(.top, 6)

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Built with")).font(.headline)
                    ForEach(Credit.all) { credit in
                        HStack(alignment: .firstTextBaseline) {
                            Link(credit.name, destination: URL(string: credit.url)!).font(.body.weight(.medium))
                            Text(L(credit.role)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if !credit.license.isEmpty { Text(credit.license).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    Text(L("Hush runs these tools as separate programs and does not include their code."))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxWidth: 560)
                .glassCard()
                .padding(.top, 8)

                HStack(spacing: 4) {
                    Text("© 2026")
                    Link("AmirhpCom", destination: URL(string: "https://amirhp.com")!)
                    Text(L("· Released under the MIT License."))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .noFocusRing()
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }
}

struct UpdatePanel: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(spacing: 8) {
            switch updater.phase {
            case .available:
                if let latest = updater.latest {
                    Text(L("Version %@ is available", latest.version)).font(.headline)
                    HStack {
                        Button(L("Update & Relaunch")) { updater.install() }.buttonStyle(.borderedProminent)
                        Button(L("Release Notes")) { NSWorkspace.shared.open(latest.page) }
                    }
                }
            case .downloading:
                ProgressView().controlSize(.small)
                Text(L("Downloading the update…")).font(.caption).foregroundStyle(.secondary)
            case .checking:
                ProgressView().controlSize(.small)
            case .upToDate:
                Label(L("You're up to date"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Button(L("Check Again")) { updater.check() }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                Button(L("Try Again")) { updater.check() }
            case .idle:
                Button(L("Check for Updates")) { updater.check() }
            }
            Toggle(L("Check for updates automatically"), isOn: $updater.autoCheck)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
    }
}
