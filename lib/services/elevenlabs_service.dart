import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'audio_cache_service.dart';

/// Result wrapper so callers know whether bytes came from cache or API.
class AudioResult {
  final Uint8List? bytes;
  final bool fromCache;

  /// `true` when the audio was not found in cache and the API call was
  /// skipped (offline / cache-only mode).
  bool get isMissing => bytes == null;

  const AudioResult({this.bytes, required this.fromCache});
}

/// Wraps the ElevenLabs Sound Generation REST API.
///
/// Endpoint: POST https://api.elevenlabs.io/v1/sound-generation
/// Docs: https://elevenlabs.io/docs/api-reference/sound-generation
class ElevenLabsService {
  ElevenLabsService._() : _dio = _buildDio();

  static final ElevenLabsService instance = ElevenLabsService._();

  static const String _baseUrl = 'https://api.elevenlabs.io/v1';
  static const String _soundGenPath = '/sound-generation';

  final Dio _dio;
  final AudioCacheService _cache = AudioCacheService.instance;

  static Dio _buildDio() {
    final apiKey = dotenv.env['ELEVENLABS_API_KEY'] ?? '';
    debugPrint(
      '[ElevenLabs] API key: ${apiKey.isEmpty ? "MISSING!" : "${apiKey.substring(0, 8)}..."}',
    );
    return Dio(
      BaseOptions(
        baseUrl: _baseUrl,
        headers: {
          'xi-api-key': apiKey,
          'Content-Type': 'application/json',
          'Accept': 'audio/mpeg',
        },
        responseType: ResponseType.bytes,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
  }

  /// When `true`, [fetchAudio] will **never** call the ElevenLabs API.
  /// If the requested audio is not in cache, it returns an [AudioResult]
  /// with `bytes == null` (`isMissing == true`) instead.
  ///
  /// Set to `true` automatically in debug builds so that every debug run
  /// is guaranteed to be API-free.  Set to `false` only when you explicitly
  /// want to generate ("pre-warm") a new asset.
  bool offlineMode = false;

  /// Fetches (or returns cached) audio bytes for [prompt].
  ///
  /// [durationSeconds] is clamped to ElevenLabs limits (0.5 – 22.0 s).
  /// Ambience should use 15 s; SFX can use shorter clips.
  ///
  /// When [offlineMode] is `true` and the audio is not cached, returns an
  /// [AudioResult] with `bytes == null` instead of calling the API.
  Future<AudioResult> fetchAudio(
    String prompt, {
    double durationSeconds = 15.0,
  }) async {
    // 1. Cache hit (memory or disk) → return immediately without an API call.
    final cached = await _cache.get(prompt);
    if (cached != null) {
      return AudioResult(bytes: cached, fromCache: true);
    }

    // 2. Offline / cache-only mode → skip API, report missing.
    if (offlineMode) {
      debugPrint(
        '[ElevenLabs] OFFLINE: audio not cached for prompt="${prompt.substring(0, prompt.length.clamp(0, 60))}...". '
        'Set ElevenLabsService.instance.offlineMode = false to generate.',
      );
      return const AudioResult(fromCache: false);
    }

    // 3. API call.
    final clampedDuration = durationSeconds.clamp(0.5, 22.0);
    debugPrint('[ElevenLabs] POST /sound-generation prompt="${prompt.substring(0, prompt.length.clamp(0, 60))}..." duration=${clampedDuration}s');

    final response = await _dio.post<dynamic>(
      _soundGenPath,
      data: {
        'text': prompt,
        'duration_seconds': clampedDuration,
        'prompt_influence': 0.3,
      },
    );

    debugPrint('[ElevenLabs] HTTP ${response.statusCode}, data type: ${response.data.runtimeType}');
    final bytes = Uint8List.fromList(response.data as List<int>);
    debugPrint('[ElevenLabs] Decoded ${bytes.length} bytes');

    // 4. Store in cache (memory + disk) before returning.
    await _cache.put(prompt, bytes);

    return AudioResult(bytes: bytes, fromCache: false);
  }

  /// Convenience overload for ambience: always requests 15 s.
  Future<AudioResult> fetchAmbience(String prompt) =>
      fetchAudio(prompt, durationSeconds: 15.0);

  /// Convenience overload for SFX: requests a shorter 4 s clip.
  Future<AudioResult> fetchSfx(String prompt) =>
      fetchAudio(prompt, durationSeconds: 4.0);

  /// Convenience overload for music layer: requests max 22 s for richer clips.
  Future<AudioResult> fetchMusic(String theme) =>
      fetchAudio('background music theme $theme, cinematic instrumental loop',
          durationSeconds: 22.0);
}
