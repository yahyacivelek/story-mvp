# Bundled Vosk STT models

The `.zip` files in this directory are gitignored. Download them locally before
running the app so the grammar-constrained STT pipeline can boot offline
without a network round-trip.

```bash
# From repo root
mkdir -p assets/vosk_models
curl -fL -o assets/vosk_models/vosk-model-small-tr-0.3.zip \
  https://alphacephei.com/vosk/models/vosk-model-small-tr-0.3.zip
```

Then run `flutter pub get && flutter run`. The model will be extracted to the
app's documents directory on first launch and reused afterwards.

Languages currently wired up in `lib/services/vosk_speech_service.dart`:
- `tr` → `vosk-model-small-tr-0.3.zip`

Add more by extending `_modelAssets` in `VoskSpeechService` and dropping the
matching zip here.
