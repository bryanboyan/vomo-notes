# Vomo

A native iOS app for reading, searching, and capturing notes in your cloud-based markdown vault. Your notes live in iCloud Drive as plain `.md` files — Vomo just gives you a fast, voice-powered way to work with them on the go.

Inspired by [Obsidian](https://obsidian.md), but Vomo is not an Obsidian app. It works with any folder of markdown files synced through iCloud Drive.

## Features

### Read & Browse

- **Markdown rendering** — Frontmatter, wiki-links, tags, code blocks, tables, and inline formatting all render natively.
- **Folder browser** — Navigate your vault's folder hierarchy with expand/collapse tree navigation.
- **Calendar view** — See notes laid out on a calendar by date. Swipe between months, tap any date to jump to that day's notes.
- **Full-text search** — Fast indexed search across all your notes with ranked results.
- **iCloud sync** — Automatic downloading and caching of iCloud Drive files. Works offline after first sync.
- **Instant launch** — Cache-first loading: notes display immediately, then a background scan picks up changes.

### Voice

- **Voice chat** — Real-time voice conversations powered by configurable AI providers. Talk to search your vault, discuss your notes, and get answers from your own content.
- **Voice transcription** — Record voice memos and save them as markdown notes. Multiple recording modes with AI-assisted summarization.
- **Quick dictation** — Instant speech-to-text using Apple's on-device recognition. Works offline, no API key needed.
- **Multi-vendor support** — Choose your preferred provider for both real-time voice and transcription: xAI, OpenAI, Deepgram, or Apple's on-device engine. Bring your own API keys — calls go directly to the provider.

### Create & Edit

- **Note creation** — Create notes via text or voice. Pick a destination folder, add frontmatter, and save.
- **Markdown editor** — Edit notes with a formatting toolbar (bold, italic, code, lists, links).
- **Property editor** — Edit YAML frontmatter fields directly.

### Dataview Queries

Supports a subset of Obsidian Dataview's DQL syntax (`TABLE`, `LIST`, `WHERE`, `SORT`, `FROM`). Query your vault's metadata directly from your notes — results render inline.

### Apple Watch

- **Wrist capture** — Raise, tap, speak. Voice recordings sync to your vault via the iPhone app.
- **Voice conversations** — Start AI-powered voice sessions directly from your watch.

## On-Device by Default

Everything runs on your device. Your notes never leave your phone unless you opt into cloud-powered voice features (transcription, voice chat). All AI providers and API calls are transparent — you always know what's being called and where your data goes.

## Getting Started

```bash
git clone https://github.com/bryanboyan/vomo-notes.git
cd vomo-notes

# Generate Xcode project (requires XcodeGen)
xcodegen generate

# Open in Xcode
open Vomo.xcodeproj
```

Build and run on a simulator or device. On first launch, pick your vault folder from iCloud Drive.

**Requirements:** iOS 17.0+, watchOS 10.0+, Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## License

MIT
