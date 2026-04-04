# Vomo

A native iOS app for reading and exploring your [Obsidian](https://obsidian.md) vault on the go. Built with SwiftUI.

## Features

**Read anywhere** -- Open any vault from iCloud Drive or local storage. Markdown renders beautifully with full support for frontmatter, wiki-links, tags, code blocks, and tables.

**Voice search** -- Find notes by talking. An agentic voice interface powered by Grok uses tool-calling to search your vault, open files, and answer questions about your notes in real time.

**Voice creation** -- Record voice memos and conversations with AI-assisted summarization. Choose recording modes (one-sided or conversational) and save modes (user thoughts, interaction notes, or raw transcript). Density slider controls compression level. Toggleable paragraphs let you include/exclude sections before saving.

**Quick dictation** -- Long-press the Create button for instant speech-to-text using Apple's on-device speech recognition. Works offline, no API key needed. Transcriptions are saved to your vault and can be pulled into notes later.

**Knowledge graph** -- Interactive force-directed graph visualization of your vault's link structure. See how your notes connect at a glance.

**Calendar view** -- Daily notes displayed on a calendar. Tap any date to see what you wrote.

**Folder browser** -- Navigate your vault's folder structure with expand/collapse tree navigation.

**Dataview queries** -- Supports a subset of Obsidian Dataview's DQL syntax (`TABLE`, `LIST`, `WHERE`, `SORT`, `FROM`). Query your vault's metadata directly from your notes.

**iCloud sync** -- Automatic downloading and caching of iCloud Drive files with progress tracking. Works offline after first sync.

**Fast** -- Two-phase loading: cached files display instantly, then a background scan picks up changes. Progressive UI updates as files are indexed.

## Requirements

- iOS 17.0+
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Getting Started

```bash
# Clone
git clone https://github.com/bryanboyan/vomo.git
cd vomo

# Generate Xcode project
xcodegen generate

# Open in Xcode
open Vomo.xcodeproj
```

Build and run on a simulator or device. On first launch, pick your Obsidian vault folder or try the built-in sample vault.

## Architecture

- **XcodeGen** -- `project.yml` is the source of truth. Run `xcodegen generate` after changes.
- **SwiftUI + @Observable** -- `VaultManager`, `FavoritesManager`, `DataviewEngine` injected via `.environment()`.
- **GRDB** -- SQLite-backed metadata index for Dataview queries.
- **MarkdownUI** -- Rich markdown rendering.
- **No server** -- Everything runs on-device. Your notes never leave your phone (except when using optional API features).

## Testing

```bash
xcodebuild test -project Vomo.xcodeproj -scheme VomoTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

64 tests across 7 suites covering parsing, indexing, graph building, caching, and query execution.

## Roadmap

### Free tier (no API key required)

Everything that runs on-device stays free:
- Vault browsing, search, calendar, knowledge graph
- Dataview queries
- Quick dictation via Apple's on-device speech recognition
- Note creation and editing
- iCloud sync

### Paid tier (API-powered features)

Features that call remote APIs require either a subscription or bringing your own API key. All models and providers are transparent — you always know what's being called.

- **Voice chat & search** -- Real-time voice conversations powered by xAI Grok Realtime API (WebSocket). Agentic tool-calling to search, open, and discuss your notes.
- **AI summarization** -- Turn voice transcripts into structured notes with configurable density, save modes, and toggleable paragraphs. Uses xAI Grok text API.
- **Cloud transcription** -- Higher-quality speech-to-text via Whisper or ElevenLabs Scribe as an upgrade from Apple's on-device recognition.
- **BYOK (Bring Your Own Key)** -- Enter your own API keys for xAI, OpenAI, or other providers. No middleman, no markup — calls go directly to the provider.

### People & connections

- **Contact book import** -- Pull contacts from the system address book. Each person becomes a note in your vault (e.g. `People/Jane Smith.md`) with frontmatter for phone, email, company, and relationship tags.
- **Connection notes** -- After a meeting or conversation, record voice notes tagged to a person. AI summarization extracts key topics, action items, and follow-ups specific to that relationship.
- **Relationship timeline** -- See all notes, voice memos, and mentions linked to a person in chronological order. Understand the full history of a relationship at a glance.
- **Mention linking** -- When a person's name appears in any note, auto-link to their People page. The knowledge graph shows your social connections alongside topic connections.
- **Voice mode context** -- "What did I last discuss with Sarah?" — voice search understands people as first-class entities in your vault.

### Apple Watch companion

- **Quick dictation** -- Raise wrist, tap, speak, done. Transcriptions sync to your vault via the iPhone app.
- **Recent notes** -- Browse and read recent or favorited notes from your wrist.
- **Voice capture** -- Start a voice memo directly from the watch, saved as a transcription for later processing on iPhone.
- **Complications** -- Quick-launch dictation or see your daily note word count at a glance.

## License

MIT
