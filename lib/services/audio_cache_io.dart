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
