import 'dart:async';
import 'dart:io';

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
    'tr': 'https://alphacephei.com/vosk/models/vosk-model-small-tr-0.42.zip',
    'en': 'https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip',
    'de': 'https://alphacephei.com/vosk/models/vosk-model-small-de-0.15.zip',
    'fr': 'https://alphacephei.com/vosk/models/vosk-model-small-fr-pguyot-0.3.zip',
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
  /// Safe to call multiple times — subsequent calls are no-ops if already
  /// listening.
  Future<bool> startListening({String languageCode = 'en'}) async {
    if (_isListening) return true;

    if (!Platform.isAndroid && !Platform.isIOS) {
      debugPrint('[VoskSTT] Vosk is only supported on Android/iOS');
      return false;
    }

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      debugPrint('[VoskSTT] microphone permission denied');
      return false;
    }

    try {
      final modelPath = await _ensureModel(languageCode);
      if (modelPath == null) return false;

      debugPrint('[VoskSTT] loading model from $modelPath');
      _model = await _vosk.createModel(modelPath);
      _recognizer = await _vosk.createRecognizer(
        model: _model!,
        sampleRate: 16000,
      );

      _speechService = await _vosk.initSpeechService(_recognizer!);
      await _speechService!.start();
      _isListening = true;

      _partialSub = _speechService!.onPartial().listen((partial) {
        final text = partial.toLowerCase().trim();
        if (text.isNotEmpty) {
          debugPrint('[VoskSTT] partial: "$text"');
          _wordController.add(text);
        }
      });

      _resultSub = _speechService!.onResult().listen((result) {
        final text = result.toLowerCase().trim();
        if (text.isNotEmpty) {
          debugPrint('[VoskSTT] final: "$text"');
          _wordController.add(text);
        }
      });

      debugPrint('[VoskSTT] recognition started (lang=$languageCode)');
      return true;
    } catch (e) {
      debugPrint('[VoskSTT] startListening failed: $e');
      _isListening = false;
      return false;
    }
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

    try {
      // loadFromNetwork checks the cache internally and skips download if
      // the model directory already exists. The returned path is always
      // the correct on-device path to the extracted model.
      final modelPath = await modelLoader.loadFromNetwork(url);
      debugPrint('[VoskSTT] Model ready at $modelPath');
      return modelPath;
    } catch (e) {
      debugPrint('[VoskSTT] Model download/extraction failed: $e');
      return null;
    }
  }
}
