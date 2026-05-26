import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vosk_flutter/vosk_flutter.dart' as vosk;

/// Offline speech recognition service backed by Vosk.
///
/// Drop-in replacement for [SpeechService] — exposes the same
/// [wordStream] interface so [StoryController] can use either without
/// changes to the matching logic.
///
/// Model lifecycle:
///   1. On first call to [startListening] the Vosk small model for the
///      requested language is downloaded via [vosk.ModelLoader.loadFromNetwork]
///      and cached on disk inside the app's support directory.
///   2. On subsequent calls the cached extraction is reused automatically.
///
/// Supported languages mirror the story JSON `book.language` ISO-639-1 codes.
class VoskSpeechService {
  VoskSpeechService._();
  static final VoskSpeechService instance = VoskSpeechService._();

  // ---------------------------------------------------------------------------
  // Public API (mirrors SpeechService)
  // ---------------------------------------------------------------------------

  final StreamController<String> _wordController =
      StreamController<String>.broadcast();

  /// Emits each recognised partial/final result as a lowercase string.
  Stream<String> get wordStream => _wordController.stream;

  bool _isListening = false;
  bool get isListening => _isListening;

  // ---------------------------------------------------------------------------
  // Model URLs (vosk-model-small-* for embedded / low-memory devices)
  // ---------------------------------------------------------------------------

  /// Maps ISO-639-1 language codes to Vosk small-model download URLs.
  ///
  /// Models are ~40–80 MB. Full list: https://alphacephei.com/vosk/models
  static const Map<String, String> _modelUrls = {
    'tr': 'https://alphacephei.com/vosk/models/vosk-model-small-tr-0.3.zip',
    'en': 'https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip',
    'de': 'https://alphacephei.com/vosk/models/vosk-model-small-de-0.15.zip',
    'fr': 'https://alphacephei.com/vosk/models/vosk-model-small-fr-0.22.zip',
    'es': 'https://alphacephei.com/vosk/models/vosk-model-small-es-0.42.zip',
    'ru': 'https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip',
  };

  // ---------------------------------------------------------------------------
  // Internal state
  // ---------------------------------------------------------------------------

  final vosk.VoskFlutterPlugin _vosk = vosk.VoskFlutterPlugin.instance();
  vosk.Model? _model;
  vosk.Recognizer? _recognizer;
  vosk.SpeechService? _speechService;

  StreamSubscription<String>? _partialSub;
  StreamSubscription<String>? _resultSub;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Downloads (if needed) and initialises the Vosk model for [languageCode],
  /// then starts continuous microphone recognition.
  ///
  /// [grammar] is an optional closed vocabulary list.  When provided the Vosk
  /// recognizer is created with [vosk_recognizer_new_grm] which restricts
  /// decoding to those words only, yielding lower CPU usage and higher
  /// accuracy for constrained scenarios.  Always include `"[unk]"` in the
  /// list so out-of-vocabulary audio still produces output.
  ///
  /// Safe to call multiple times — subsequent calls are no-ops if already
  /// listening.
  Future<bool> startListening(
      {String languageCode = 'en', List<String>? grammar}) async {
    if (_isListening) return true;

    if (!Platform.isAndroid && !Platform.isIOS) {
      debugPrint('[VoskSTT] Vosk is only supported on Android/iOS');
      return false;
    }

    // Check first to avoid hanging on already-granted permissions on some OEMs.
    var micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) {
      micStatus = await Permission.microphone.request();
    }
    if (!micStatus.isGranted) {
      debugPrint('[VoskSTT] microphone permission denied: $micStatus');
      return false;
    }
    debugPrint('[VoskSTT] microphone permission: $micStatus');

    try {
      String? modelPath = await _ensureModel(languageCode);
      if (modelPath == null) return false;

      debugPrint('[VoskSTT] loading model from $modelPath');
      try {
        _model = await _vosk.createModel(modelPath);
      } catch (_) {
        // Model dir exists but is corrupt — delete it and try once more.
        debugPrint('[VoskSTT] createModel failed, purging cache and retrying');
        await _purgeCachedModel(languageCode);
        modelPath = await _ensureModel(languageCode);
        if (modelPath == null) return false;
        _model = await _vosk.createModel(modelPath);
      }
      _recognizer = await _vosk.createRecognizer(
        model: _model!,
        sampleRate: 16000,
        grammar: grammar,
      );
      if (grammar != null) {
        debugPrint(
          '[VoskSTT] grammar-constrained recognizer: ${grammar.length} tokens'
        );
      }

      _speechService = await _vosk.initSpeechService(_recognizer!);
      await _speechService!.start(
        onRecognitionError: (e) => debugPrint('[VoskSTT] recognition error: $e'),
      );
      _isListening = true;

      _partialSub = _speechService!.onPartial().listen((json) {
        try {
          final data = jsonDecode(json) as Map<String, dynamic>;
          final text = (data['partial'] as String? ?? '').toLowerCase().trim();
          if (text.isNotEmpty) {
            debugPrint('[VoskSTT] partial: "$text"');
            _wordController.add(text);
          }
        } catch (_) {}
      });

      _resultSub = _speechService!.onResult().listen((json) {
        try {
          final data = jsonDecode(json) as Map<String, dynamic>;
          final text = (data['text'] as String? ?? '').toLowerCase().trim();
          if (text.isNotEmpty) {
            debugPrint('[VoskSTT] final: "$text"');
            _wordController.add(text);
          }
        } catch (_) {}
      });

      debugPrint(
        '[VoskSTT] recognition started '
        '(lang=$languageCode, grammar=${grammar != null ? "${grammar.length} tokens" : "unrestricted"})'
      );
      return true;
    } catch (e) {
      debugPrint('[VoskSTT] startListening failed: $e');
      _isListening = false;
      return false;
    }
  }

  /// Swaps the active grammar on-the-fly **without** restarting the audio
  /// pipeline.  Call this on every scene transition to narrow the vocabulary
  /// to the current scene's keywords.
  ///
  /// No-op if recognition is not currently active.
  Future<void> updateGrammar(List<String> grammar) async {
    final rec = _recognizer;
    if (rec == null || !_isListening) {
      debugPrint('[VoskSTT] updateGrammar: not listening — skipped');
      return;
    }
    await rec.setGrammar(grammar);
    debugPrint('[VoskSTT] grammar updated: ${grammar.length} tokens');
  }

  Future<void> stopListening() async {
    _isListening = false;
    await _partialSub?.cancel();
    await _resultSub?.cancel();
    _partialSub = null;
    _resultSub = null;
    try {
      await _speechService?.stop();
    } catch (_) {}
    _speechService = null;
    _recognizer?.dispose();
    _recognizer = null;
    _model?.dispose();
    _model = null;
    debugPrint('[VoskSTT] stopped');
  }

  void dispose() {
    _isListening = false;
    _partialSub?.cancel();
    _resultSub?.cancel();
    _speechService?.stop();
    _recognizer?.dispose();
    _model?.dispose();
    _wordController.close();
  }

  // ---------------------------------------------------------------------------
  // Model download / cache helper
  // ---------------------------------------------------------------------------

  /// Returns the path to the extracted Vosk model directory for [languageCode].
  /// Downloads and extracts the model on first call; reuses the cache after.
  Future<String?> _ensureModel(String languageCode) async {
    final url = _modelUrls[languageCode.toLowerCase()];
    if (url == null) {
      debugPrint('[VoskSTT] No model URL for language: $languageCode');
      return null;
    }

    final modelLoader = vosk.ModelLoader();
    final modelName = url.split('/').last.replaceAll('.zip', '');

    debugPrint('[VoskSTT] Ensuring model "$modelName"');

    // Check if a previously cached model dir is actually valid (non-empty).
    // ModelLoader.isModelAlreadyLoaded only checks directory existence, not
    // contents. A partial/failed extraction leaves an empty dir that causes
    // "Failed to create a model" from the native layer.
    final alreadyCached = await modelLoader.isModelAlreadyLoaded(modelName);
    bool forceReload = false;
    if (alreadyCached) {
      final cachedPath = await modelLoader.modelPath(modelName);
      final dir = Directory(cachedPath);
      final contents = dir.existsSync() ? dir.listSync(recursive: false) : [];
      if (contents.isEmpty) {
        debugPrint('[VoskSTT] Cached model dir is empty — forcing re-download');
        forceReload = true;
      } else {
        // Vosk models require at minimum conf/ and am/ subdirectories.
        final dirs = contents.whereType<Directory>().map((e) => path.basename(e.path)).toSet();
        final valid = dirs.contains('conf') && dirs.contains('am');
        if (!valid) {
          debugPrint('[VoskSTT] Cached model incomplete (dirs: $dirs) — forcing re-download');
          forceReload = true;
        }
      }
    }

    try {
      final modelPath = await modelLoader.loadFromNetwork(
        url,
        forceReload: forceReload,
      );
      debugPrint('[VoskSTT] Model ready at $modelPath');
      return modelPath;
    } catch (e) {
      debugPrint('[VoskSTT] Model download/extraction failed: $e');
      return null;
    }
  }

  Future<void> _purgeCachedModel(String languageCode) async {
    final url = _modelUrls[languageCode.toLowerCase()];
    if (url == null) return;
    final modelName = url.split('/').last.replaceAll('.zip', '');
    final modelLoader = vosk.ModelLoader();
    final cachedPath = await modelLoader.modelPath(modelName);
    final dir = Directory(cachedPath);
    if (dir.existsSync()) {
      debugPrint('[VoskSTT] Deleting corrupt model dir: $cachedPath');
      await dir.delete(recursive: true);
    }
  }
}
