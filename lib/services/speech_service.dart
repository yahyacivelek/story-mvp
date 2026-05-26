import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Wraps `speech_to_text` with:
/// - microphone permission handling
/// - continuous listen → restart loop (STT sessions time out after ~30 s)
/// - a broadcast [Stream<String>] of recognised word chunks
class SpeechService {
  SpeechService._();
  static final SpeechService instance = SpeechService._();

  static const _audioUtils = MethodChannel('com.example.story/audio_utils');

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
  bool _useOnDevice = false;
  bool _lastErrorWasBusy = false;

  // Prevents counting multiple errors that fire for the same listen session
  // (e.g. error_client + error_speech_timeout both fire when the online STT
  // drops). Without this guard errCount grows by 2 per failed session,
  // hitting the 5-second backoff tier after just 3 quiet sessions.
  bool _erroredThisSession = false;

  Future<void> _onError(dynamic e) async {
    final msg = e?.errorMsg?.toString() ?? e.toString();
    debugPrint('[Speech] error: $msg');

    // Only count one error per listen session even if the plugin fires several
    // (e.g. error_client + error_speech_timeout both fire for one bad session).
    if (_erroredThisSession) return;
    _erroredThisSession = true;

    // Silence events (timeout, no_match) are NOT engine failures — they happen
    // whenever the user pauses between sentences. Don't apply any backoff;
    // let the loop restart immediately at 120ms.
    const silenceErrors = ['error_speech_timeout', 'error_no_match'];
    if (silenceErrors.any((t) => msg.contains(t))) {
      _lastErrorWasBusy = false;
      return;
    }

    _consecutiveErrors++;
    _lastErrorWasBusy = msg.contains('error_busy') ||
        msg.contains('error_recognizer_busy');

    // On-device packs often fail under background audio; fall back to online.
    if (msg.contains('error_client') && _useOnDevice) {
      _useOnDevice = false;
      debugPrint('[Speech] error_client — switching to online recognizer');
    }

    // Non-silence errors may not trigger 'done' status with cancelOnError: false.
    // Force-stop the dead session and schedule a restart to keep the loop alive.
    await _stt.stop();
    _scheduleRestart();
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

    // Always use online STT — looping ambience drowns the mic and on-device
    // packs time out with no partial results on Android.
    _useOnDevice = false;
    _consecutiveErrors = 0;
    _lastErrorWasBusy = false;

    _isListening = true;
    _muteNotificationStream();
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
    _restartTimer?.cancel();
    await _stt.stop();
    _unmuteNotificationStream();
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
        // NOTE: Do NOT reset `_consecutiveErrors` on `'listening'` — Android
        // fires that status whenever the recognizer *starts*, even when it
        // immediately times out without decoding any audio (common on
        // non-English on-device packs). Resetting here would mask a broken
        // engine forever and the online fallback would never engage. The
        // counter is only cleared on a successful onResult below.
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

    _erroredThisSession = false;
    debugPrint(
      '[Speech] listen() locale=$_localeId onDevice=$_useOnDevice errCount=$_consecutiveErrors',
    );
    _stt.listen(
      onResult: (result) {
        final text = result.recognizedWords.toLowerCase().trim();
        // Log every result — including empty finals — so we can tell whether
        // the recognizer is hearing anything at all.
        debugPrint(
          '[Speech] onResult final=${result.finalResult} '
          'conf=${result.confidence.toStringAsFixed(2)} '
          'text="$text"',
        );
        if (text.isNotEmpty) {
          // Real recognition happened — engine is healthy, clear the
          // fallback counter.
          _consecutiveErrors = 0;
          _lastErrorWasBusy = false;
          _wordController.add(text);
        }
      },
      // Android hard-caps at ~60 s; use max to minimise open/close cycles.
      listenFor: const Duration(seconds: 58),
      // Shorter pause: with ambience playing, longer pauseFor often makes the
      // recognizer wait forever for a perceived silence and then time out
      // without ever emitting a final. 5 s is enough for a sentence break.
      pauseFor: const Duration(seconds: 5),
      localeId: _localeId,
      onSoundLevelChange: null,
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: false,
        onDevice: _useOnDevice,
        autoPunctuation: false,
      ),
    );
  }

  /// Schedules the next listen attempt. Uses exponential-ish backoff when
  /// errors keep firing so a misconfigured recognizer can't burn the CPU
  /// and the audio stack with hundreds of restarts per minute.
  void _scheduleRestart() {
    if (!_isListening) return;
    _restartTimer?.cancel();
    final Duration delay;
    if (_lastErrorWasBusy) {
      // Mic still held by a previous session — wait before retrying.
      delay = const Duration(seconds: 2);
    } else if (_consecutiveErrors == 0) {
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
    _unmuteNotificationStream();
    _wordController.close();
  }

  void _muteNotificationStream() {
    _audioUtils.invokeMethod('muteNotificationStream').catchError((_) {});
  }

  void _unmuteNotificationStream() {
    _audioUtils.invokeMethod('unmuteNotificationStream').catchError((_) {});
  }
}
