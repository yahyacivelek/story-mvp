import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

// Conditional imports — resolved at compile time per platform.
import 'audio_cache_io.dart' if (dart.library.html) 'audio_cache_web.dart' as platform;

/// Two-tier audio byte cache:
///   1. In-memory `Map<String, Uint8List>` (hot, per-session).
///   2. Persistent storage (native: on-disk files; web: IndexedDB).
///
/// Keys are the exact ElevenLabs prompt string. On native the filename is
/// `sha1(prompt).mp3`; on web the key is stored in IndexedDB. The cache
/// survives app restarts and hot reloads — you generate each sound once and
/// reuse it across every debug session.
class AudioCacheService {
  AudioCacheService._();

  static final AudioCacheService instance = AudioCacheService._();

  static const String _storeName = 'elevenlabs_cache';

  final Map<String, Uint8List> _memory = {};

  String _keyFor(String prompt) {
    final digest = sha1.convert(utf8.encode(prompt));
    return '$digest';
  }

  /// Returns the cached bytes for [prompt] (memory first, then persistent),
  /// or `null` if not cached anywhere.
  Future<Uint8List?> get(String prompt) async {
    final mem = _memory[prompt];
    if (mem != null) return mem;

    try {
      final key = _keyFor(prompt);
      final bytes = await platform.read(key, _storeName);
      if (bytes != null) {
        _memory[prompt] = bytes;
        debugPrint('[AudioCache] persistent hit (${bytes.length}B) $key');
        return bytes;
      }
    } catch (e) {
      debugPrint('[AudioCache] persistent read failed: $e');
    }
    return null;
  }

  /// Stores [bytes] under [prompt] in both memory and persistent storage.
  Future<void> put(String prompt, Uint8List bytes) async {
    _memory[prompt] = bytes;
    try {
      final key = _keyFor(prompt);
      await platform.write(key, bytes, _storeName);
      debugPrint('[AudioCache] persisted (${bytes.length}B) $key');
    } catch (e) {
      debugPrint('[AudioCache] persistent write failed: $e');
    }
  }

  /// Returns `true` if audio for [prompt] is cached in memory or persistent storage.
  Future<bool> contains(String prompt) async {
    if (_memory.containsKey(prompt)) return true;
    try {
      final key = _keyFor(prompt);
      return await platform.exists(key, _storeName);
    } catch (_) {
      return false;
    }
  }

  /// Number of in-memory entries (does not scan persistent storage).
  int get size => _memory.length;

  /// Clears both the in-memory map and persistent storage.
  Future<void> clear() async {
    _memory.clear();
    try {
      await platform.clear(_storeName);
    } catch (e) {
      debugPrint('[AudioCache] clear failed: $e');
    }
  }

  /// Removes a single entry from memory and persistent storage.
  Future<void> evict(String prompt) async {
    _memory.remove(prompt);
    try {
      final key = _keyFor(prompt);
      await platform.delete(key, _storeName);
    } catch (e) {
      debugPrint('[AudioCache] evict failed: $e');
    }
  }
}
