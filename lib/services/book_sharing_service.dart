import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scanned_book_model.dart';

class BookSharingService {
  static final BookSharingService instance = BookSharingService._();
  BookSharingService._();

  /// Packs the book's metadata and scanned images into a `.story` zip file and shares it.
  Future<void> exportBook(ScannedBook book) async {
    try {
      final archive = Archive();

      // 1. Create and add book metadata
      final metaData = {
        'id': book.id,
        'title': book.title,
        'createdAt': book.createdAt.toIso8601String(),
        'pageCount': book.pageImagePaths.length,
      };
      final metaJson = jsonEncode(metaData);
      final metaBytes = utf8.encode(metaJson);
      archive.addFile(ArchiveFile('book_meta.json', metaBytes.length, metaBytes));

      // 2. Add each page image file
      for (int i = 0; i < book.pageImagePaths.length; i++) {
        final imgPath = book.pageImagePaths[i];
        final file = File(imgPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final ext = path.extension(imgPath).isNotEmpty ? path.extension(imgPath) : '.jpg';
          final zipFileName = 'page_$i$ext';
          archive.addFile(ArchiveFile(zipFileName, bytes.length, bytes));
        } else {
          debugPrint('Warning: Image file does not exist at $imgPath');
        }
      }

      // 3. Encode to ZIP format
      final zipEncoder = ZipEncoder();
      final zipBytes = zipEncoder.encode(archive);

      // 4. Save to temporary directory
      final tempDir = await getTemporaryDirectory();
      // Use the book title (sanitized) as file name
      final sanitizedTitle = book.title.replaceAll(RegExp(r'[^\w\s\-\.]'), '').trim().replaceAll(RegExp(r'\s+'), '_');
      final fileName = sanitizedTitle.isNotEmpty ? '$sanitizedTitle.story' : 'scanned_book.story';
      final tempFile = File(path.join(tempDir.path, fileName));
      await tempFile.writeAsBytes(zipBytes);

      // 5. Trigger Native Share Sheet
      final xFile = XFile(tempFile.path, mimeType: 'application/zip');
      await Share.shareXFiles(
        [xFile],
        text: '"${book.title}" kitabını seninle paylaştım! Bu dosyayı "Story" uygulaması ile açarak okuyabilirsin.',
      );
    } catch (e) {
      debugPrint('Error exporting book: $e');
      rethrow;
    }
  }

  /// Parses a `.story` zip file, extracts its images, and returns a new [ScannedBook].
  Future<ScannedBook> importBookFile(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // 1. Find book_meta.json
      ArchiveFile? metaFile;
      for (final archFile in archive) {
        if (archFile.name == 'book_meta.json') {
          metaFile = archFile;
          break;
        }
      }

      if (metaFile == null) {
        throw Exception('Geçersiz kitap dosyası: book_meta.json bulunamadı.');
      }

      final metaContent = utf8.decode(metaFile.content as List<int>);
      final metaMap = jsonDecode(metaContent) as Map<String, dynamic>;
      final title = metaMap['title'] as String? ?? 'İthal Kitap';

      // 2. Setup the target directory with a unique ID
      final bookId = 'book_imported_${DateTime.now().millisecondsSinceEpoch}';
      final appDocDir = await getApplicationDocumentsDirectory();
      final bookDir = Directory(path.join(appDocDir.path, 'scanned_books', bookId));
      await bookDir.create(recursive: true);

      // 3. Extract and sort image files
      final imageFiles = archive.where((f) => f.name.startsWith('page_') && f.isFile).toList();
      imageFiles.sort((a, b) {
        final aNum = int.tryParse(RegExp(r'\d+').firstMatch(a.name)?.group(0) ?? '0') ?? 0;
        final bNum = int.tryParse(RegExp(r'\d+').firstMatch(b.name)?.group(0) ?? '0') ?? 0;
        return aNum.compareTo(bNum);
      });

      final List<String> localPaths = [];
      for (int i = 0; i < imageFiles.length; i++) {
        final imgFile = imageFiles[i];
        final ext = path.extension(imgFile.name).isNotEmpty ? path.extension(imgFile.name) : '.jpg';
        final destFile = File(path.join(bookDir.path, 'page_$i$ext'));
        await destFile.writeAsBytes(imgFile.content as List<int>);
        localPaths.add(destFile.path);
      }

      if (localPaths.isEmpty) {
        throw Exception('Kitapta içe aktarılacak sayfa görseli bulunamadı.');
      }

      return ScannedBook(
        id: bookId,
        title: title,
        createdAt: DateTime.now(),
        pageImagePaths: localPaths,
      );
    } catch (e) {
      debugPrint('Error importing book: $e');
      rethrow;
    }
  }
}
