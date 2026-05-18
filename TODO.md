# TODO

## 🔴 Next session — top priority

### 1. Apply stash + implement ambience/music toggles (INCOMPLETE from last session)

The stash (`git stash@{0}`) contains partial implementation of audio toggles.
Apply + finish the work:

```bash
git stash pop
```

Then manually complete `scene_header.dart` (the stash only has audio_controller changes):

**`audio_controller.dart` changes needed (in stash):**
- Add `ambienceEnabled` / `musicEnabled` bool fields to `AudioState` (default `true`)
- Add `setAmbienceEnabled(bool)` and `setMusicEnabled(bool)` to `AudioController`
  — pause/resume the respective player, update state
- Guard `loadAndPlayAmbience`, `_crossfadeAmbience`, `loadAndPlayMusic` with `if (!state.ambienceEnabled/musicEnabled) return;`

**`scene_header.dart` changes needed (NOT in stash — must be written fresh):**
- `_AudioPills` needs: `ambienceEnabled`, `musicEnabled`, `onToggleAmbience`, `onToggleMusicEnabled` params
- Wrap ambience and music pills in `GestureDetector` + `Tooltip`
- Disabled state: use `volume_off` / `music_off` icon at 40% opacity
- `SceneHeader.build()` passes these to `_AudioPills`:
  ```dart
  ambienceEnabled: audioState.ambienceEnabled,
  musicEnabled: audioState.musicEnabled,
  onToggleAmbience: () => ref.read(audioControllerProvider.notifier).setAmbienceEnabled(!audioState.ambienceEnabled),
  onToggleMusicEnabled: () => ref.read(audioControllerProvider.notifier).setMusicEnabled(!audioState.musicEnabled),
  ```

After implementing: `flutter analyze` should pass with 0 errors.

### 2. STT `error_busy` loop (observed in runtime logs)

`/tmp/story_run3.log` shows continuous `error_busy` on STT — the STT and audio session conflict repeatedly.
The STT restart loop keeps firing even when `error_busy` is returned.
**Fix**: add `error_busy` to the backoff error types in `SpeechService` (treat same as `error_client`).

### 3. Commit + push setup

No git remote is configured (`git remote -v` returns empty).
Set up a remote before next deployment:
```bash
git remote add origin <repo-url>
git push -u origin master
```

---

## 🟡 Medium priority

### 4. STT language fallback indicator in UI
When `SpeechService` falls back from on-device to online recognizer, the user gets no feedback.
Add a small indicator in SceneHeader (e.g., "🌐" badge on mic pill) when online STT is active.

### 5. ElevenLabs API key missing / invalid — graceful error
Currently, if `.env` is missing or key is wrong, the app throws on first audio fetch with no recovery UI.
Add a user-visible snackbar or inline error state.

### 6. Cache size management
`AudioCacheService` on-disk cache has no eviction policy — it grows unbounded.
Add LRU eviction or max-size limit (e.g., 50 MB).

### 7. End-of-story state
When the last scene's `next_scene_id == 'none'`, there's no "finished" UI.
Consider a completion screen or scroll-to-top / replay button.

---

## 🟢 Nice to have

- Volume sliders for ambience / music (instead of just on/off)
- Visual scene progress bar (dots or mini-map)
- Persist toggle preferences across restarts (`SharedPreferences`)
- Dark/light theme toggle
- Multiple stories support (story picker screen)
