/// Web persistent cache using IndexedDB via package:web / dart:js_interop.
/// Works in both JS and Wasm compilation modes.
/// Exposes top-level functions matching the API expected by audio_cache_service.dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

const String _dbName = 'story_audio_cache';
const int _dbVersion = 1;

// ---------------------------------------------------------------------------
// IDB helpers
// ---------------------------------------------------------------------------

/// Wraps an [web.IDBRequest] in a [Future] that completes on success/error.
Future<T> _idbRequest<T>(web.IDBRequest request) {
  final completer = Completer<T>();
  request.onsuccess = ((web.Event _) {
    completer.complete(request.result as T);
  }).toJS;
  request.onerror = ((web.Event _) {
    final err = request.error;
    completer.completeError(err != null ? err : Exception('IDB error'));
  }).toJS;
  return completer.future;
}

/// Opens (or creates) the IndexedDB database, creating [storeName] if needed.
Future<web.IDBDatabase> _openDb(String storeName) async {
  final request = web.window.indexedDB.open(_dbName, _dbVersion);
  request.onupgradeneeded = ((web.IDBVersionChangeEvent _) {
    final db = request.result as web.IDBDatabase;
    final names = db.objectStoreNames;
    bool found = false;
    for (var i = 0; i < names.length; i++) {
      if (names.item(i) == storeName) {
        found = true;
        break;
      }
    }
    if (!found) {
      db.createObjectStore(storeName);
    }
  }).toJS;
  return _idbRequest<web.IDBDatabase>(request);
}

/// Converts a JS value read from IndexedDB back to [Uint8List].
Uint8List _jsToBytes(JSAny? value) {
  if (value == null) throw StateError('null IDB value');
  // Stored as JSUint8Array via bytes.toJS
  if (value is JSUint8Array) return value.toDart;
  // Fallback: ArrayBuffer
  if (value is JSArrayBuffer) return (value.toDart).asUint8List();
  throw StateError('Unexpected IDB value type: ${value.runtimeType}');
}

// ---------------------------------------------------------------------------
// Public API (matches audio_cache_io.dart signatures)
// ---------------------------------------------------------------------------

Future<Uint8List?> read(String key, String storeName) async {
  try {
    final db = await _openDb(storeName);
    final tx = db.transaction(storeName.toJS, 'readonly');
    final store = tx.objectStore(storeName);
    final result = await _idbRequest<JSAny?>(store.get(key.toJS));
    if (result == null) return null;
    return _jsToBytes(result);
  } catch (e) {
    debugPrint('[AudioCache/Web] read failed: $e');
    return null;
  }
}

Future<void> write(String key, Uint8List bytes, String storeName) async {
  try {
    final db = await _openDb(storeName);
    final tx = db.transaction(storeName.toJS, 'readwrite');
    final store = tx.objectStore(storeName);
    await _idbRequest<JSAny?>(store.put(bytes.toJS, key.toJS));
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
    final tx = db.transaction(storeName.toJS, 'readwrite');
    final store = tx.objectStore(storeName);
    await _idbRequest<JSAny?>(store.delete(key.toJS));
  } catch (e) {
    debugPrint('[AudioCache/Web] delete failed: $e');
  }
}

Future<void> clear(String storeName) async {
  try {
    final db = await _openDb(storeName);
    final tx = db.transaction(storeName.toJS, 'readwrite');
    final store = tx.objectStore(storeName);
    await _idbRequest<JSAny?>(store.clear());
  } catch (e) {
    debugPrint('[AudioCache/Web] clear failed: $e');
  }
}

/// Lists all cached entries in IndexedDB using getAllKeys/getAll.
Future<List<CacheEntry>> listEntries(String storeName) async {
  try {
    final db = await _openDb(storeName);
    final tx = db.transaction(storeName.toJS, 'readonly');
    final store = tx.objectStore(storeName);

    final keysRaw = await _idbRequest<JSAny?>(store.getAllKeys());
    final valsRaw = await _idbRequest<JSAny?>(store.getAll());

    final keys = (keysRaw as JSArray).toDart;
    final vals = (valsRaw as JSArray).toDart;

    final results = <CacheEntry>[];
    for (var i = 0; i < keys.length && i < vals.length; i++) {
      final keyStr = (keys[i] as JSString).toDart;
      // Skip internal index entries (e.g. "_index").
      if (keyStr.startsWith('_')) continue;
      final bytes = _jsToBytes(vals[i]);
      results.add(CacheEntry(key: keyStr, bytes: bytes));
    }
    return results;
  } catch (e) {
    debugPrint('[AudioCache/Web] listEntries failed: $e');
    return [];
  }
}

/// Reads the prompt→sha1 reverse-index from IndexedDB.
Future<Map<String, String>> readIndex(String storeName) async {
  try {
    final db = await _openDb(storeName);
    final tx = db.transaction(storeName.toJS, 'readonly');
    final store = tx.objectStore(storeName);
    final result = await _idbRequest<JSAny?>(store.get('_index'.toJS));
    if (result == null) return {};
    final json = (result as JSString).toDart;
    final map = (jsonDecode(json) as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, v as String));
    return map;
  } catch (e) {
    debugPrint('[AudioCache/Web] readIndex failed: $e');
    return {};
  }
}

/// Writes the prompt→sha1 reverse-index to IndexedDB.
Future<void> writeIndex(String storeName, Map<String, String> index) async {
  try {
    final db = await _openDb(storeName);
    final tx = db.transaction(storeName.toJS, 'readwrite');
    final store = tx.objectStore(storeName);
    final json = jsonEncode(index);
    await _idbRequest<JSAny?>(store.put(json.toJS, '_index'.toJS));
  } catch (e) {
    debugPrint('[AudioCache/Web] writeIndex failed: $e');
  }
}

/// A single cached audio entry returned by [listEntries].
class CacheEntry {
  final String key;
  final Uint8List bytes;
  const CacheEntry({required this.key, required this.bytes});
}
