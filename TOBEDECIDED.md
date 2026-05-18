# To Be Decided

## Audio UX decisions

### Toggle behaviour: pause vs stop+clear
When ambience is toggled OFF, should the player:
- **A) Pause** — resume instantly from same position when re-enabled (current plan in stash)
- **B) Stop and clear** — re-fetch from ElevenLabs/cache next time (fresh audio, costs a cache hit)

Current stash implements option A (pause/resume). Feels better for UX.

### Music enabled-by-default per scene
Some scenes in `story.json` already have `music_layer.enabled: false`.
Should the UI toggle override this, or should the scene-level JSON flag always win?
Current plan: user toggle wins (if user enables music, scene JSON `enabled: false` is ignored).

### Toggle scope: session vs scene
Does toggling ambience OFF mean:
- **A) Off for this scene only** — re-enables on next scene transition
- **B) Off until user turns it back on** — survives scene transitions
Option B is simpler and current plan.

## Story content

### story.json completeness
The current story "Ginger the Giraffe" is a single Turkish-language test story (6 scenes, 13 pages).
Decide whether to:
- Extend it to a full story
- Add a story picker (requires architectural change to load multiple JSONs)
- Keep it as demo content

## Architecture

### Persist toggle state across restarts
Currently `ambienceEnabled` / `musicEnabled` reset to `true` on every app launch.
Decision: add `SharedPreferences` persistence or leave as-is (always on at startup)?

### Riverpod migration to @riverpod annotations
Currently all providers are hand-written `StateNotifierProvider`s.
Migrating to code-gen (`@riverpod`) would improve type safety and reduce boilerplate,
but requires `build_runner` in the dev workflow.
Not urgent — decide before adding more providers.
