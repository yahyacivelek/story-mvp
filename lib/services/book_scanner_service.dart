import 'dart:convert';
import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../models/scanned_book_model.dart';

final bookScannerProvider =
    StateNotifierProvider<BookScannerService, List<ScannedBook>>((ref) {
  return BookScannerService();
});

class BookScannerService extends StateNotifier<List<ScannedBook>> {
  BookScannerService() : super([]) {
    _init();
  }

  bool _initialized = false;
  late Directory _appDocDir;
  late File _indexFile;

  Future<void> _init() async {
    _appDocDir = await getApplicationDocumentsDirectory();
    final booksDir = Directory(path.join(_appDocDir.path, 'scanned_books'));
    if (!await booksDir.exists()) {
      await booksDir.create(recursive: true);
    }
    _indexFile = File(path.join(booksDir.path, 'books_index.json'));

    if (await _indexFile.exists()) {
      try {
        final content = await _indexFile.readAsString();
        final List<dynamic> jsonList = jsonDecode(content);
        state = jsonList.map((e) => ScannedBook.fromJson(e)).toList();
      } catch (e) {
        debugPrint('Error reading books index: $e');
      }
    }
    _initialized = true;
  }

  Future<void> _saveIndex() async {
    if (!_initialized) return;
    final jsonList = state.map((b) => b.toJson()).toList();
    await _indexFile.writeAsString(jsonEncode(jsonList));
  }

  /// Opens the native document scanner and creates a new book
  Future<ScannedBook?> scanNewBook(String title) async {
    try {
      final List<String>? pictures = await CunningDocumentScanner.getPictures();
      if (pictures == null || pictures.isEmpty) return null;

      final bookId = 'book_${DateTime.now().millisecondsSinceEpoch}';
      final bookDir = Directory(path.join(_appDocDir.path, 'scanned_books', bookId));
      await bookDir.create(recursive: true);

      final List<String> localPaths = [];
      for (int i = 0; i < pictures.length; i++) {
        final sourceFile = File(pictures[i]);
        final ext = path.extension(sourceFile.path).isNotEmpty ? path.extension(sourceFile.path) : '.jpg';
        final destFile = File(path.join(bookDir.path, 'page_$i$ext'));
        await sourceFile.copy(destFile.path);
        localPaths.add(destFile.path);
      }

      final newBook = ScannedBook(
        id: bookId,
        title: title,
        createdAt: DateTime.now(),
        pageImagePaths: localPaths,
      );

      state = [...state, newBook];
      await _saveIndex();
      return newBook;
    } catch (e) {
      debugPrint('Error scanning book: $e');
      return null;
    }
  }

  /// Add an imported book to the state and save
  Future<void> importScannedBook(ScannedBook book) async {
    state = [...state, book];
    await _saveIndex();
  }

  /// Reorder a page in a book
  Future<void> reorderPage(String bookId, int oldIndex, int newIndex) async {
    final bookIndex = state.indexWhere((b) => b.id == bookId);
    if (bookIndex == -1) return;

    final book = state[bookIndex];
    final paths = List<String>.from(book.pageImagePaths);
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final item = paths.removeAt(oldIndex);
    paths.insert(newIndex, item);

    final updatedBook = book.copyWith(pageImagePaths: paths);
    final newState = [...state];
    newState[bookIndex] = updatedBook;
    state = newState;
    await _saveIndex();
  }

  /// Update the generated story JSON path for a book
  Future<void> updateGeneratedStoryPath(String bookId, String jsonPath) async {
    final bookIndex = state.indexWhere((b) => b.id == bookId);
    if (bookIndex == -1) return;

    final updatedBook = state[bookIndex].copyWith(generatedStoryJsonPath: jsonPath);
    final newState = [...state];
    newState[bookIndex] = updatedBook;
    state = newState;
    await _saveIndex();
  }

  /// Delete a book and its files
  Future<void> deleteBook(String bookId) async {
    final bookIndex = state.indexWhere((b) => b.id == bookId);
    if (bookIndex == -1) return;
    
    state = state.where((b) => b.id != bookId).toList();
    await _saveIndex();

    try {
      final bookDir = Directory(path.join(_appDocDir.path, 'scanned_books', bookId));
      if (await bookDir.exists()) {
        await bookDir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('Error deleting book files: $e');
    }
  }

  /// Delete a specific page from a book
  Future<void> deletePage(String bookId, int pageIndex) async {
    final bookIndex = state.indexWhere((b) => b.id == bookId);
    if (bookIndex == -1) return;

    final book = state[bookIndex];
    final paths = List<String>.from(book.pageImagePaths);
    
    if (pageIndex >= 0 && pageIndex < paths.length) {
      final fileToDelete = File(paths[pageIndex]);
      paths.removeAt(pageIndex);
      
      final updatedBook = book.copyWith(pageImagePaths: paths);
      final newState = [...state];
      newState[bookIndex] = updatedBook;
      state = newState;
      await _saveIndex();

      try {
        if (await fileToDelete.exists()) {
          await fileToDelete.delete();
        }
      } catch (e) {
        debugPrint('Error deleting page file: $e');
      }
    }
  }
}
