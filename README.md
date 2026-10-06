# Hush

Everything to text, right on your Mac. Hush turns audio and video into text offline with
[whisper.cpp](https://github.com/ggml-org/whisper.cpp), reads text aloud, and answers Telegram
voice messages with text, using your Mac as the server.

## Features

- **Transcribe** OGG/Opus, WAV, MP3, M4A, FLAC, MP4, MKV, MOV, WebM and more. Export TXT, TXT with times, SRT, VTT, LRC, CSV, JSON, Markdown, Word and PDF (right-to-left aware).
- **Queue** with progress and ETA, pause, reorder and retry. When it finishes: notification, sound, Telegram message, quit, sleep or shut down.
- **History and editor**: playback synced to each line, editing, find and replace, Persian cleanup (ی، ک، نیم‌فاصله).
- **Telegram**: send audio and text (as caption, message or file). The bot mode turns voice, audio and video messages into text. Chats are paired on the Mac (approve with Allow / Deny).
- **Speak**: text to speech with macOS voices and [Piper](https://github.com/OHF-Voice/piper1-gpl) (Persian voices included). Save as WAV/M4A/MP3/OGG or send as a Telegram voice message.
- **Live dictation** from the microphone through a local whisper-server.
- **Models and voices manager** with downloads from Hugging Face (or hf-mirror.com) and proxy support.
- **Tools manager**: installs and updates whisper.cpp, FFmpeg and Piper with Homebrew.
- **Appearance**: Liquid Glass (macOS 26+), translucent with a blur slider, or a solid color. English and Persian (RTL).
- Watch folders, Finder service, Dock progress, menu bar status, self-update from GitHub Releases.

## Requirements

macOS 14 or later, Apple silicon. Hush installs the rest from Settings → Tools:
`brew install whisper.cpp ffmpeg`.

## Build

```
./scripts/build-app.sh          # dist/Hush.app, Hush.zip (+ .sig) and a DMG
swift test                      # unit tests for HushCore
```

Releases: `gh release create vX.Y.Z dist/Hush.zip dist/Hush.zip.sig dist/Hush.dmg`.
The zip is signed with the Ed25519 key from `swift scripts/release-key.swift generate`; its public key is `HushPublicEDKey` in `Resources/Info.plist`.

## Credits

Hush runs these tools as separate programs:
whisper.cpp (MIT), OpenAI Whisper models (MIT), FFmpeg (LGPL/GPL), Piper (GPL-3.0) and its voices (per-voice licenses),
Silero VAD (MIT), Homebrew (BSD-2-Clause), the Telegram Bot API.

## License

MIT © 2026 [AmirhpCom](https://amirhp.com)
