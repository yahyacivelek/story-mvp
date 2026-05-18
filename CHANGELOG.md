# Changelog

## [Unreleased]

### Planned
- Ambience and music on/off toggles (tappable pills in SceneHeader)
  — `AudioState.ambienceEnabled` / `musicEnabled`, `setAmbienceEnabled()` / `setMusicEnabled()` in AudioController
  — stash@{0} has the audio_controller diff; scene_header.dart toggle UI still needs implementation

## [0.5.0] — 2026-05-18 (commit 38fc5e0)

### Added
- **Scroll-based auto-transition** — at 90% scroll depth, schedules scene advance after 3 s
- **Duration-based auto-transition** — `scene_duration_estimate_seconds` timer fires if user hasn't scrolled
- **Transition cooldown** — 10 s minimum between automatic transitions
- **Structured exit/entry cues** — `CueKeyword` model, `SceneActivation.exitCues` / `entryCues` parsed from JSON
- **Audio crossfade** — `transitionToScene()` with evolve / continue / replace modes
- **Music layer** — dedicated `_musicPlayer`, `loadAndPlayMusic()`, `stopMusic()`
- **`readingProgress`** and **`isAutoTransitioning`** in `StoryState`
- **Floating scene picker FAB** in StoryScreen (replaces permanent sidebar)

## [0.4.0] — 2026-05-18 (commit 1d3e9ca)

### Changed
- Redesigned StoryScreen to immersive full-screen reader (no permanent sidebar)
- Slim SceneHeader top bar with compact audio status pills
- SceneSidebar shown as modal bottom sheet

## [0.3.0] — 2026-05-18 (commit ccef8e8)

### Added
- Music layer wired from `story.json` into audio playback

## [0.2.0] — 2026-05-18 (commit 434c084)

### Added
- CLAUDE.md with architecture docs

## [0.1.0] — initial

### Added
- Initial Flutter project with ElevenLabs audio, STT, Riverpod state
