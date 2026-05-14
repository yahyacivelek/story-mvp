import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Wraps `speech_to_text` with:
/// - microphone permission handling
/// - continuous listen → restart loop (STT sessions time out after ~30 s)
/// - a broadcast [Stream<String>] of recognised word chunks
class SpeechService {
  SpeechService._();
  static final SpeechService instance = SpeechService._();

  final SpeechToText _stt = SpeechToText();

  final StreamController<String> _wordController =
      StreamController<String>.broadcast();

  /// Emits each recognised partial/final result as a lowercase string.
  Stream<String> get wordStream => _wordController.stream;

  bool _isListening = false;
  bool _isInitialised = false;
  String _localeId = 'en-US';

  bool get isListening => _isListening;

  // -------------------------------------------------------------------------

  Future<bool> _init() async {
    if (_isInitialised) return true;
    _isInitialised = await _stt.initialize(
      onError: _onError,
      onStatus: (s) => debugPrint('[Speech] status: $s'),
    );
    debugPrint('[Speech] initialised: $_isInitialised');
    return _isInitialised;
  }

  // Error handling -----------------------------------------------------------
  //
  // `error_client` fires when the recognizer can't start at all — most often
  // because on-device recognition is requested but no offline model is
  // installed for the requested locale. Without backoff this produces a
  // tight start→error→start loop that hammers the mic and floods the log.

  int _consecutiveErrors = 0;
  bool _useOnDevice = true;

  void _onError(dynamic e) {
    final msg = e?.errorMsg?.toString() ?? e.toString();
    debugPrint('[Speech] error: $msg');

    _consecutiveErrors++;

    // Two immediate `error_client` failures in a row almost always means
    // the on-device recognizer isn't available for this locale. Fall back
    // to the online recognizer permanently for the rest of the session.
    if (_useOnDevice && msg.contains('error_client') && _consecutiveErrors >= 2) {
      debugPrint('[Speech] on-device unavailable, falling back to online recognizer');
      _useOnDevice = false;
    }
  }

  /// Requests RECORD_AUDIO permission, initialises STT, and starts the
  /// continuous listen loop.  Safe to call multiple times.
  ///
  /// [languageCode] is an ISO-639-1 code (e.g. 'en', 'tr', 'de'). It is
  /// mapped to a BCP-47 locale tag that Android STT understands.
  Future<bool> startListening({String languageCode = 'en'}) async {
    if (_isListening) return true;

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      debugPrint('[Speech] microphone permission denied');
      return false;
    }

    final ok = await _init();
    if (!ok) return false;

    // Resolve the locale against what the device actually has installed.
    // Android's `onDevice` recognizer is picky: requesting `tr-TR` when the
    // installed offline pack is registered as `tr_TR` (underscore) or just
    // `tr` will trigger `error_client` on every listen attempt. We query
    // the actual locale list and pick the closest match to what we want.
    _localeId = await _resolveLocale(languageCode);
    debugPrint('[Speech] resolved locale: $_localeId');

    _isListening = true;
    _listenLoop();
    return true;
  }

  /// Picks the best installed locale for the requested language code.
  /// Falls back to the BCP-47 default if no match is found.
  Future<String> _resolveLocale(String languageCode) async {
    final preferred = _toBcp47(languageCode);
    try {
      final locales = await _stt.locales();
      final lang = languageCode.toLowerCase();
      debugPrint(
        '[Speech] available locales: ${locales.map((l) => l.localeId).join(', ')}',
      );

      // 1. Exact match against the preferred BCP-47 tag.
      for (final l in locales) {
        if (l.localeId.toLowerCase() == preferred.toLowerCase()) {
          return l.localeId;
        }
      }
      // 2. Any locale whose language part matches (tr-TR, tr_TR, tr-CY, ...).
      for (final l in locales) {
        final id = l.localeId.toLowerCase();
        if (id == lang || id.startsWith('${lang}_') || id.startsWith('$lang-')) {
          return l.localeId;
        }
      }
    } catch (e) {
      debugPrint('[Speech] _resolveLocale failed: $e');
    }
    return preferred;
  }

  /// Maps a 2-letter ISO-639-1 language code to the most common BCP-47 locale
  /// tag used by Android's SpeechRecognizer.
  static String _toBcp47(String lang) {
    const map = {
      'tr': 'tr-TR',
      'en': 'en-US',
      'de': 'de-DE',
      'fr': 'fr-FR',
      'es': 'es-ES',
      'it': 'it-IT',
      'pt': 'pt-BR',
      'ru': 'ru-RU',
      'ja': 'ja-JP',
      'ko': 'ko-KR',
      'zh': 'zh-CN',
      'ar': 'ar-SA',
      'nl': 'nl-NL',
      'pl': 'pl-PL',
      'sv': 'sv-SE',
    };
    return map[lang.toLowerCase()] ?? '${lang.toLowerCase()}-${lang.toUpperCase()}';
  }

  /// Stops the continuous loop and the current STT session.
  Future<void> stopListening() async {
    _isListening = false;
    await _stt.stop();
    debugPrint('[Speech] stopped');
  }

  // -------------------------------------------------------------------------
  // Continuous loop — STT has a ~30 s hard limit; we restart automatically.
  // -------------------------------------------------------------------------

  Timer? _restartTimer;
  bool _statusListenerAttached = false;

  void _listenLoop() {
    if (!_isListening) return;

    // Attach the status listener once — re-assigning it on every restart
    // can cause stale closures to schedule duplicate restarts.
    if (!_statusListenerAttached) {
      _stt.statusListener = (status) {
        debugPrint('[Speech] status: $status');
        if (!_isListening) return;
        // A successful `listening` status means the recognizer started
        // cleanly — reset the error counter so a later hiccup doesn't trip
        // the fallback prematurely.
        if (status == 'listening') {
          _consecutiveErrors = 0;
        }
        // Only restart on a true session end. `notListening` also fires
        // during natural speech pauses while the session is still alive —
        // restarting then would cycle the mic needlessly and (on online
        // STT) re-trigger the system start/stop chime.
        if (status == 'done') {
          _scheduleRestart();
        }
      };
      _statusListenerAttached = true;
    }

    _stt.listen(
      onResult: (result) {
        final text = result.recognizedWords.toLowerCase().trim();
        if (text.isNotEmpty) {
          debugPrint('[Speech] heard: "$text"');
          _wordController.add(text);
        }
      },
      // Android hard-caps at ~60 s; use max to minimise open/close cycles.
      listenFor: const Duration(seconds: 58),
      // Long pause tolerance so background ambience doesn't trigger early stop.
      pauseFor: const Duration(seconds: 30),
      localeId: _localeId,
      onSoundLevelChange: null,
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: false,
        // Prefer on-device (no system chime, no online round-trip). If the
        // first attempts fail with `error_client`, `_onError` flips this off
        // and we fall back to the online recognizer for the rest of the
        // session.
        onDevice: _useOnDevice,
        autoPunctuation: false,
      ),
    );
  }

  /// Schedules the next listen attempt. Uses exponential-ish backoff when
  /// errors keep firing so a misconfigured recognizer can't burn the CPU
  /// and the audio stack with hundreds of restarts per minute.
  void _scheduleRestart() {
    _restartTimer?.cancel();
    final Duration delay;
    if (_consecutiveErrors == 0) {
      // Healthy path: tiny gap so the user perceives continuous listening.
      delay = const Duration(milliseconds: 120);
    } else if (_consecutiveErrors < 3) {
      delay = const Duration(milliseconds: 500);
    } else if (_consecutiveErrors < 6) {
      delay = const Duration(seconds: 2);
    } else {
      // Recognizer is clearly broken — back off hard to stop hammering it.
      delay = const Duration(seconds: 5);
    }
    _restartTimer = Timer(delay, _listenLoop);
  }

  void dispose() {
    _isListening = false;
    _restartTimer?.cancel();
    _stt.stop();
    _wordController.close();
  }
}
