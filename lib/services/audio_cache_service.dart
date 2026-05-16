import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Two-tier audio byte cache:
///   1. In-memory `Map<String, Uint8List>` (hot, per-session).
///   2. Persistent on-disk files under the app's documents directory.
///
/// Keys are the exact ElevenLabs prompt string. On disk, the filename is
/// `sha1(prompt).mp3` so the cache survives app restarts and hot reloads —
/// you generate each sound once and reuse it across every debug session.
class AudioCacheService {
  AudioCacheService._();

  static final AudioCacheService instance = AudioCacheService._();

  static const String _subdir = 'elevenlabs_cache';

  final Map<String, Uint8List> _memory = {};
  Future<Directory>? _dirFuture;

  Future<Directory> _ensureDir() {
    return _dirFuture ??= () async {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$_subdir');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      debugPrint('[AudioCache] persistent dir: ${dir.path}');
      return dir;
    }();
  }

  String _filenameFor(String prompt) {
    final digest = sha1.convert(utf8.encode(prompt));
    return '$digest.mp3';
  }

  Future<File> _fileFor(String prompt) async {
    final dir = await _ensureDir();
    return File('${dir.path}/${_filenameFor(prompt)}');
  }

  /// Returns the cached bytes for [prompt] (memory first, then disk),
  /// or `null` if not cached anywhere.
  Future<Uint8List?> get(String prompt) async {
    final mem = _memory[prompt];
    if (mem != null) return mem;

    try {
      final file = await _fileFor(prompt);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        _memory[prompt] = bytes;
        debugPrint(
          '[AudioCache] disk hit (${bytes.length}B) ${_filenameFor(prompt)}',
        );
        return bytes;
      }
    } catch (e) {
      debugPrint('[AudioCache] disk read failed: $e');
    }
    return null;
  }

  /// Stores [bytes] under [prompt] in both memory and on disk.
  Future<void> put(String prompt, Uint8List bytes) async {
    _memory[prompt] = bytes;
    try {
      final file = await _fileFor(prompt);
      await file.writeAsBytes(bytes, flush: true);
      debugPrint(
        '[AudioCache] persisted (${bytes.length}B) ${_filenameFor(prompt)}',
      );
    } catch (e) {
      debugPrint('[AudioCache] disk write failed: $e');
    }
  }

  /// Returns `true` if audio for [prompt] is cached in memory or on disk.
  Future<bool> contains(String prompt) async {
    if (_memory.containsKey(prompt)) return true;
    try {
      final file = await _fileFor(prompt);
      return file.exists();
    } catch (_) {
      return false;
    }
  }

  /// Number of in-memory entries (does not scan disk).
  int get size => _memory.length;

  /// Clears both the in-memory map and the on-disk directory.
  Future<void> clear() async {
    _memory.clear();
    try {
      final dir = await _ensureDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        _dirFuture = null;
      }
    } catch (e) {
      debugPrint('[AudioCache] clear failed: $e');
    }
  }

  /// Removes a single entry from memory and disk.
  Future<void> evict(String prompt) async {
    _memory.remove(prompt);
    try {
      final file = await _fileFor(prompt);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('[AudioCache] evict failed: $e');
    }
  }
}
