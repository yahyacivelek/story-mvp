# Story

Interactive audio storytelling app — a Flutter app that plays dynamically generated ambient audio and SFX synchronized to what is being read aloud via speech recognition.

## Environment setup

Create a `.env` file in the project root:

```
GOOGLE_API_KEY=your_gemini_key_here
ELEVENLABS_API_KEY=your_elevenlabs_key_here
```

## Running the app

```bash
# Run on a connected device/emulator
flutter run

# Build release APK
flutter build apk --release

# Analyze (lint + type check)
flutter analyze

# Run tests
flutter test
```

## Book analysis tool (`tools/analyze_book.py`)

Converts photographed book pages into the cinematic story JSON consumed by the app.

### Single-stage — languages without Vosk OOV support (e.g. English)

One Gemini call: images → full story JSON.

```bash
uv run tools/analyze_book.py analyze assets/raw/cat
uv run tools/analyze_book.py analyze assets/raw/cat --dry-run
uv run tools/analyze_book.py analyze assets/raw/cat --output assets/stories/cat.json
```

### Two-stage — languages with Vosk OOV support (e.g. Turkish)

**Stage 1** — OCR: images → `_pages.json`

```bash
uv run tools/analyze_book.py extract-pages assets/raw/baykut
uv run tools/analyze_book.py extract-pages assets/raw/baykut --dry-run
```

**Stage 2** — Build: `_pages.json` + OOV check → full story JSON

```bash
uv run tools/analyze_book.py build-story assets/stories/baykut_pages.json
uv run tools/analyze_book.py build-story assets/stories/baykut_pages.json --dry-run
uv run tools/analyze_book.py build-story assets/stories/baykut_pages.json \
    --model assets/vosk_models/vosk-model-small-tr-0.3.zip
```

Each raw book directory must contain a `book_meta.json`:

```json
{
  "id": "baykut",
  "title": "Baykuş Kut",
  "language": "tr",
  "pageCount": 24
}
```

### Other analysis tools

```bash
# Check story trigger keywords against Vosk model vocabulary
uv run tools/check_story_vocab.py \
    --model assets/vosk_models/vosk-model-small-tr-0.3.zip \
    --story assets/stories/baykut.json

# Check all stories at once
uv run tools/check_story_vocab.py \
    --model assets/vosk_models/vosk-model-small-tr-0.3.zip \
    --story assets/stories/

# Merge runtime audio files
uv run tools/merge_audio_runtime.py
```

## Assets

- `assets/stories/` — story JSON files + `manifest.json`
- `assets/schemas/story_schema.json` — JSON schema for story files
- `assets/audio/` — pre-warmed audio cache (SHA1-keyed `.mp3` files)
- `assets/raw/` — raw photographed book page images (per-book subdirectories)
- `assets/vosk_models/` — Vosk model zips for OOV checking (not committed)
