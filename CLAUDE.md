# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run on a connected device/emulator
flutter run

# Build release APK
flutter build apk --release

# Analyze (lint + type check)
flutter analyze

# Run tests
flutter test

# Run a single test file
flutter test test/widget_test.dart

# Regenerate Riverpod providers (after adding/changing @riverpod annotations)
dart run build_runner build --delete-conflicting-outputs
```

## Environment setup

Copy `.env.example` to `.env` (or create `.env` in the project root) and set:
```
ELEVENLABS_API_KEY=your_key_here
```
The `.env` file is bundled as a Flutter asset and loaded at startup via `flutter_dotenv`.

## Architecture

The app is an interactive audio storytelling reader. It loads a story from `assets/story.json` and plays dynamically generated ambient audio and SFX from ElevenLabs, synchronized to what is being read aloud via speech recognition.

### Data flow

`assets/story.json` → `StoryData` model → `StoryController` → `StoryScreen` UI

The JSON has three key sections:
- `book`: metadata (title, language)
- `pages`: list of narrative text pages with mood/visual hints
- `scene_graph`: scenes grouping pages, each with `scene_audio` (ambience layers) and `audio_opportunities` (SFX triggers with keyword lists)

### State management (Riverpod)

Two `StateNotifierProvider`s manage all state:

- **`storyControllerProvider`** (`StoryController` / `StoryState`): owns story data, the active scene index, and speech recognition. On init it loads the JSON, starts the ambience for scene 0, and begins the STT listen loop.

- **`audioControllerProvider`** (`AudioController` / `AudioState`): owns two `just_audio` `AudioPlayer` instances — one for looping background ambience, one for one-shot SFX. It also configures `AudioSession` for Android AudioFocus.

### Audio pipeline

1. `StoryController._onWords()` receives a rolling 60-word transcript from `SpeechService`.
2. `FuzzyMatcher.matches()` checks the transcript against each `AudioOpportunity`'s `triggerPrimaryKeywords` and `triggerSecondaryKeywords` (primary = +2 pts, secondary = +1 pt, normalised to 0–1). There is also an 8-second minimum cooldown per opportunity to prevent repeated firing from STT partial results.
3. On a match, `AudioController.playSfx()` is called with the opportunity.
4. Scene transitions use the same fuzzy-match logic against the *next* scene's summary/page words.
5. `ElevenLabsService.fetchAmbience()` / `fetchSfx()` call the ElevenLabs Sound Generation API and route through `AudioCacheService`, which is a two-tier cache: in-memory `Map` (hot) + on-disk files under `elevenlabs_cache/` (SHA1-keyed `.mp3` files, survives restarts).

### Speech recognition

`SpeechService` wraps `speech_to_text` with:
- Continuous listen-restart loop (STT hard-caps at ~58 s, auto-restarts on `done`)
- Exponential backoff on consecutive errors (up to 5 s)
- Automatic fallback from on-device to online recognizer after 2 `error_client`-type failures
- Locale resolution: maps the JSON `book.language` ISO-639-1 code to BCP-47, then resolves against the device's installed locales

### UI structure

```
StoryScreen
├── SceneSidebar          — fixed 260 px left panel; scene list with mood/energy tags
└── _SceneMainArea
    ├── SceneHeader        — scene title, mood badge, audio status indicator
    ├── _StoryBody         — scrollable page content
    │   └── InteractiveTextWidget  — RichText with tappable SFX anchor spans
    └── SfxLegend          — bottom bar listing all audio opportunities for the scene
```

`InteractiveTextWidget` splits `page.fullText` around each `AudioOpportunity.triggerAnchor.value` using a combined regex (anchors sorted longest-first), rendering trigger words as highlighted tappable spans. Tapping fires `playSfx` directly; speech matching does the same automatically.

### Key design decisions

- **No code generation for providers**: providers are hand-written `StateNotifierProvider`s (not `@riverpod` annotated), so `build_runner` is only needed if you add new generated providers.
- **Bytes-in-memory audio**: `_BytesAudioSource` (in `audio_controller.dart`) wraps `Uint8List` as a `StreamAudioSource` so `just_audio` can play API-fetched audio without temp files.
- **AudioFocus**: `handleAudioSessionActivation: false` on both players — the app holds permanent `GAIN` focus via `audio_session` and manually ducks the ambience player during STT interruptions rather than pausing.
