# Done

## Core architecture
- [x] Story loaded from `assets/story.json` → StoryData model → StoryController
- [x] Riverpod state: `storyControllerProvider` + `audioControllerProvider`
- [x] ElevenLabs API: ambience, SFX, music via `ElevenLabsService`
- [x] Two-tier audio cache: in-memory Map + on-disk SHA1-keyed .mp3 (`AudioCacheService`)
- [x] `_BytesAudioSource` adapter — plays Uint8List via just_audio without temp files
- [x] AudioSession configured for Android AudioFocus (GAIN, permanent, manual duck on STT)

## Speech recognition
- [x] Continuous listen-restart loop (auto-restart on `done`, 58 s STT cap)
- [x] Exponential backoff on consecutive errors (up to 5 s)
- [x] Fallback from on-device to online recognizer after 2 `error_client` failures
- [x] Locale resolution: JSON `book.language` ISO-639-1 → BCP-47 → installed device locales

## Audio features
- [x] Background ambience (looping, intensity-based volume)
- [x] One-shot SFX per AudioOpportunity
- [x] Music layer (dedicated player, 0.6× volume under ambience)
- [x] Scene crossfade: evolve / continue / replace transition modes
- [x] Volume duck during STT interruptions

## Matching / triggers
- [x] FuzzyMatcher: primary (+2) / secondary (+1) keyword scoring, normalised 0–1
- [x] 8 s minimum cooldown per audio opportunity (prevents STT partial-result re-firing)
- [x] `trigger_once_per_scene` support (24 h cooldown)
- [x] Anchor phrase exact-match check (separate from fuzzy)
- [x] Scene transition fuzzy matching: exit_cues (primary) + entry_cues (secondary)
- [x] Structured `CueKeyword` model parsed from JSON `exit_cues` / `entry_cues`
- [x] Fallback to page-text keywords when cues empty

## Auto-progression
- [x] Scroll-based auto-transition (≥90% scroll → 3 s delay → next scene)
- [x] Duration-based auto-transition (`scene_duration_estimate_seconds` timer)
- [x] 10 s cooldown between automatic transitions

## UI
- [x] Immersive full-screen StoryScreen
- [x] SceneHeader: slim top bar, mood emoji, energy label, 3 status pills (ambience / music / mic)
- [x] InteractiveTextWidget: RichText with tappable SFX anchor spans
- [x] Floating scene picker FAB → modal bottom sheet (SceneSidebarSheet)
- [x] SfxLegend: bottom bar listing all audio opportunities
- [x] Heard-text strip shown while STT is active
- [x] Scrollbar with per-scene `_PageDivider`
