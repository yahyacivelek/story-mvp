import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Native (mobile/desktop) persistent cache using the file system.
/// Exposes top-level functions matching the API expected by audio_cache_service.dart.

Future<Directory> _ensureDir(String storeName) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/$storeName');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

Future<Uint8List?> read(String key, String storeName) async {
  final dir = await _ensureDir(storeName);
  final file = File('${dir.path}/$key.mp3');
  if (await file.exists()) {
    return await file.readAsBytes();
  }
  return null;
}

Future<void> write(String key, Uint8List bytes, String storeName) async {
  final dir = await _ensureDir(storeName);
  final file = File('${dir.path}/$key.mp3');
  await file.writeAsBytes(bytes, flush: true);
}

Future<bool> exists(String key, String storeName) async {
  final dir = await _ensureDir(storeName);
  final file = File('${dir.path}/$key.mp3');
  return file.exists();
}

Future<void> delete(String key, String storeName) async {
  final dir = await _ensureDir(storeName);
  final file = File('${dir.path}/$key.mp3');
  if (await file.exists()) {
    await file.delete();
  }
}

Future<void> clear(String storeName) async {
  final dir = await _ensureDir(storeName);
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}

/// Lists all cached entries in persistent storage.
/// Returns a list of [CacheEntry] with the sha1 key and audio bytes.
Future<List<CacheEntry>> listEntries(String storeName) async {
  final dir = await _ensureDir(storeName);
  final results = <CacheEntry>[];
  if (!await dir.exists()) return results;

  await for (final entity in dir.list()) {
    if (entity is File && entity.path.endsWith('.mp3')) {
      final fileName = entity.uri.pathSegments.last;
      final key = fileName.replaceAll('.mp3', '');
      final bytes = await entity.readAsBytes();
      results.add(CacheEntry(key: key, bytes: bytes));
    }
  }
  return results;
}

/// Reads the prompt→sha1 reverse-index JSON file from persistent storage.
Future<Map<String, String>> readIndex(String storeName) async {
  final dir = await _ensureDir(storeName);
  final file = File('${dir.path}/_index.json');
  if (!await file.exists()) return {};
  final json = await file.readAsString();
  final map = jsonDecode(json) as Map<String, dynamic>;
  return map.map((k, v) => MapEntry(k, v as String));
}

/// Writes the prompt→sha1 reverse-index JSON file to persistent storage.
Future<void> writeIndex(String storeName, Map<String, String> index) async {
  final dir = await _ensureDir(storeName);
  final file = File('${dir.path}/_index.json');
  final json = jsonEncode(index);
  await file.writeAsString(json, flush: true);
}

/// A single cached audio entry returned by [listEntries].
class CacheEntry {
  final String key;
  final Uint8List bytes;
  const CacheEntry({required this.key, required this.bytes});
}
