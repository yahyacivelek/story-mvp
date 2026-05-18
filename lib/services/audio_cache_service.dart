import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

// Conditional imports — resolved at compile time per platform.
// dart.library.html  → JS-compiled web (dart:html available)
// dart.library.wasm   → Wasm-compiled web (dart:js_interop available)
import 'audio_cache_io.dart'
    if (dart.library.html) 'audio_cache_web.dart'
    if (dart.library.wasm) 'audio_cache_web.dart'
    as platform;

// Reverse-lookup index: sha1 hex → original prompt string.
// Populated by [put] and restored from persistent storage by [preloadAll].
Map<String, String> _sha1ToPrompt = {};

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
      _sha1ToPrompt[key] = prompt;
      await platform.write(key, bytes, _storeName);
      // Persist the reverse index so it survives app restarts.
      await platform.writeIndex(_storeName, _sha1ToPrompt);
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
      _sha1ToPrompt.remove(key);
      await platform.delete(key, _storeName);
      await platform.writeIndex(_storeName, _sha1ToPrompt);
    } catch (e) {
      debugPrint('[AudioCache] evict failed: $e');
    }
  }

  // -----------------------------------------------------------------------
  // Startup pre-warm
  // -----------------------------------------------------------------------

  /// Scans persistent storage and loads **every** cached audio file into the
  /// in-memory map so that subsequent [get] calls are instant cache hits
  /// without any disk I/O or API calls.
  ///
  /// Also restores the prompt→sha1 reverse index from persistent storage
  /// so that preloaded entries are keyed by their original prompt string.
  ///
  /// Call once at app startup (e.g. in `main()` before `runApp`).
  Future<int> preloadAll() async {
    try {
      // 1. Restore the reverse index first (sha1 → prompt).
      _sha1ToPrompt = await platform.readIndex(_storeName);

      // 2. Load all cached audio files into memory.
      final entries = await platform.listEntries(_storeName);

      var loaded = 0;
      for (final entry in entries) {
        final sha1Key = entry.key;
        final bytes = entry.bytes;
        // Prefer known prompt from reverse index; fall back to sha1 key itself.
        final prompt = _sha1ToPrompt[sha1Key] ?? sha1Key;
        _memory[prompt] = bytes;
        loaded++;
      }

      debugPrint(
        '[AudioCache] preloadAll: $loaded entries loaded into memory '
        '(${_memory.length} total in-memory, '
        '${_sha1ToPrompt.length} index entries)',
      );
      return loaded;
    } catch (e) {
      debugPrint('[AudioCache] preloadAll failed: $e');
      return 0;
    }
  }

  /// Returns a diagnostic snapshot of the cache state.
  Map<String, dynamic> get status => {
        'inMemoryCount': _memory.length,
        'inMemoryBytes': _memory.values.fold<int>(0, (sum, b) => sum + b.length),
        'knownPrompts': _sha1ToPrompt.length,
      };
}
