/// Web persistent cache using IndexedDB via idb_shim.
/// Exposes top-level functions matching the API expected by audio_cache_service.dart.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb.dart';
import 'package:idb_shim/idb_browser.dart';

const String _dbName = 'story_audio_cache';
const int _dbVersion = 1;

Future<Database> _openDb(String storeName) async {
  final idb = idbFactoryBrowser;
  return idb.open(_dbName, version: _dbVersion,
      onUpgradeNeeded: (VersionChangeEvent event) {
    final db = event.database;
    if (!db.objectStoreNames.contains(storeName)) {
      db.createObjectStore(storeName);
    }
  });
}

Future<Uint8List?> read(String key, String storeName) async {
  try {
    final db = await _openDb(storeName);
    final tx = db.transaction(storeName, idbModeReadOnly);
    final store = tx.objectStore(storeName);
    final result = await store.getObject(key);
    await tx.completed;
    if (result == null) return null;
    if (result is Uint8List) return result;
    if (result is ByteBuffer) return result.asUint8List();
    if (result is List<int>) return Uint8List.fromList(result);
    debugPrint('[AudioCache/Web] unexpected type: ${result.runtimeType}');
    return null;
  } catch (e) {
    debugPrint('[AudioCache/Web] read failed: $e');
    return null;
  }
}

Future<void> write(String key, Uint8List bytes, String storeName) async {
  try {
    final db = await _openDb(storeName);
    final tx = db.transaction(storeName, idbModeReadWrite);
    final store = tx.objectStore(storeName);
    store.put(bytes, key);
    await tx.completed;
  } catch (e) {
    debugPrint('[AudioCache/Web] write failed: $e');
  }
}

Future<bool> exists(String key, String storeName) async {
  try {
    final result = await read(key, storeName);
    return result != null;
  } catch (_) {
    return false;
  }
}

Future<void> delete(String key, String storeName) async {
  try {
    final db = await _openDb(storeName);
    final tx = db.transaction(storeName, idbModeReadWrite);
    final store = tx.objectStore(storeName);
    store.delete(key);
    await tx.completed;
  } catch (e) {
    debugPrint('[AudioCache/Web] delete failed: $e');
  }
}

Future<void> clear(String storeName) async {
  try {
    final db = await _openDb(storeName);
    final tx = db.transaction(storeName, idbModeReadWrite);
    final store = tx.objectStore(storeName);
    store.clear();
    await tx.completed;
  } catch (e) {
    debugPrint('[AudioCache/Web] clear failed: $e');
  }
}
