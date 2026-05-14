import 'dart:typed_data';

/// In-memory audio byte cache keyed by the exact API prompt string.
///
/// This prevents redundant ElevenLabs API calls when the same sound is
/// requested more than once within a session.
class AudioCacheService {
  AudioCacheService._();

  static final AudioCacheService instance = AudioCacheService._();

  final Map<String, Uint8List> _cache = {};

  /// Returns the cached bytes for [prompt], or `null` if not cached.
  Uint8List? get(String prompt) => _cache[prompt];

  /// Stores [bytes] under [prompt].
  void put(String prompt, Uint8List bytes) {
    _cache[prompt] = bytes;
  }

  /// Returns `true` if audio for [prompt] is already cached.
  bool contains(String prompt) => _cache.containsKey(prompt);

  /// Returns the number of cached entries.
  int get size => _cache.length;

  /// Clears the entire cache.
  void clear() => _cache.clear();

  /// Removes a single entry (e.g. on playback failure).
  void evict(String prompt) => _cache.remove(prompt);
}
