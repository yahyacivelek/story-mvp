import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Deepgram streaming speech recognition service.
/// Uses WebSocket API for real-time transcription.
class DeepgramSpeechService {
  DeepgramSpeechService._();
  static final DeepgramSpeechService instance = DeepgramSpeechService._();

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  final StreamController<String> _wordController =
      StreamController<String>.broadcast();

  /// Emits each recognised result as a lowercase string.
  Stream<String> get wordStream => _wordController.stream;

  bool _isListening = false;
  bool get isListening => _isListening;

  bool _isSpeaking = false;

  // ---------------------------------------------------------------------------
  // Internal state
  // ---------------------------------------------------------------------------

  final AudioRecorder _recorder = AudioRecorder();
  WebSocketChannel? _wsChannel;
  StreamSubscription<dynamic>? _wsSub;
  StreamSubscription<Uint8List>? _recordSub;

  // Deepgram API configuration
  static const String _deepgramWsUrl = 'wss://api.deepgram.com/v1/listen';

  /// Get API key from .env file (DEEPGRAM_API_KEY)
  String? get _apiKey {
    final key = dotenv.env['DEEPGRAM_API_KEY'];
    if (key == null || key.isEmpty) {
      debugPrint('[DeepgramSTT] DEEPGRAM_API_KEY not found in .env');
      return null;
    }
    return key;
  }

  /// Maps ISO-639-1 to Deepgram language codes
  static const Map<String, String> _languageMap = {
    'tr': 'tr',
    'en': 'en-US',
    'de': 'de',
    'fr': 'fr',
    'es': 'es',
    'ru': 'ru',
  };

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<bool> startListening({String languageCode = 'en'}) async {
    if (_isListening) return true;

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      debugPrint('[DeepgramSTT] microphone permission denied');
      return false;
    }

    final apiKey = _apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      debugPrint('[DeepgramSTT] DEEPGRAM_API_KEY not set');
      return false;
    }

    try {
      // Build WebSocket URL with query params
      final lang = _languageMap[languageCode.toLowerCase()] ?? 'en-US';
      final uri = Uri.parse(_deepgramWsUrl).replace(queryParameters: {
        'language': lang,
        'model': 'nova-3',
        'punctuate': 'false', // Keep it clean for matching
        'smart_format': 'false',
        'interim_results': 'true', // Enable partial results
        'vad_events': 'true',
        'encoding': 'linear16',
        'sample_rate': '16000',
        'channels': '1',
      });

      // Connect to Deepgram WebSocket
      _wsChannel = WebSocketChannel.connect(
        uri,
        protocols: ['token', apiKey],
      );

      // Wait for connection to open
      await _wsChannel!.ready;
      debugPrint('[DeepgramSTT] WebSocket connected');

      // Start recording
      const recordConfig = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      );

      final stream = await _recorder.startStream(recordConfig);

      // Always forward audio so Deepgram VAD can detect speech start
      _recordSub = stream.listen(
        (data) => _wsChannel?.sink.add(data),
        onError: (e) => debugPrint('[DeepgramSTT] record error: $e'),
      );

      // Listen for transcription results
      _wsSub = _wsChannel!.stream.listen(
        _onTranscriptMessage,
        onError: (e) => debugPrint('[DeepgramSTT] WS error: $e'),
        onDone: () => debugPrint('[DeepgramSTT] WS closed'),
      );

      _isListening = true;
      debugPrint('[DeepgramSTT] listening started (lang=$lang)');
      return true;
    } catch (e) {
      debugPrint('[DeepgramSTT] startListening failed: $e');
      await _cleanup();
      return false;
    }
  }

  void _onTranscriptMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;

      // Handle VAD events
      final type = data['type'] as String?;
      if (type == 'SpeechStarted') {
        _isSpeaking = true;
        debugPrint('[DeepgramSTT] speech started');
        return;
      } else if (type == 'UtteranceEnd') {
        _isSpeaking = false;
        debugPrint('[DeepgramSTT] utterance end');
        return;
      }

      final channel = data['channel'] as Map<String, dynamic>?;
      final alternatives = channel?['alternatives'] as List<dynamic>?;

      if (alternatives == null || alternatives.isEmpty) return;

      final transcript = alternatives.first['transcript'] as String? ?? '';
      final isFinal = data['is_final'] as bool? ?? false;

      if (transcript.isNotEmpty && _isSpeaking) {
        final text = transcript.toLowerCase().trim();
        debugPrint(
            '[DeepgramSTT] ${isFinal ? "final" : "partial"}: "$text"');
        _wordController.add(text);
      }
    } catch (e) {
      debugPrint('[DeepgramSTT] parse error: $e');
    }
  }

  Future<void> stopListening() async {
    _isListening = false;
    await _cleanup();
    debugPrint('[DeepgramSTT] stopped');
  }

  Future<void> _cleanup() async {
    _isSpeaking = false;
    await _wsSub?.cancel();
    await _recordSub?.cancel();

    try {
      await _recorder.stop();
    } catch (_) {}

    await _wsChannel?.sink.close();
    _wsChannel = null;
    _wsSub = null;
    _recordSub = null;
  }

  void dispose() {
    _isListening = false;
    _cleanup();
    _wordController.close();
  }
}
