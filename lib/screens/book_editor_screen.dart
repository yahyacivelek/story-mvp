import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../services/book_scanner_service.dart';
import '../services/book_sharing_service.dart';
import '../services/gemini_analyzer_service.dart';

class BookEditorScreen extends ConsumerStatefulWidget {
  final String bookId;
  const BookEditorScreen({super.key, required this.bookId});

  @override
  ConsumerState<BookEditorScreen> createState() => _BookEditorScreenState();
}

class _BookEditorScreenState extends ConsumerState<BookEditorScreen> {
  bool _isGenerating = false;
  String _statusText = '';

  Future<void> _generateStory() async {
    final book = ref.read(bookScannerProvider).firstWhere((b) => b.id == widget.bookId);
    
    setState(() {
      _isGenerating = true;
      _statusText = 'Starting...';
    });

    try {
      final jsonString = await GeminiAnalyzerService.instance.generateStoryJson(
        book,
        onProgress: (status) {
          setState(() {
            _statusText = status;
          });
        },
      );

      if (jsonString != null) {
        // Save to file
        final appDocDir = await getApplicationDocumentsDirectory();
        final filePath = path.join(appDocDir.path, 'scanned_books', book.id, 'story.json');
        final file = File(filePath);
        await file.writeAsString(jsonString);

        // Update book index
        await ref.read(bookScannerProvider.notifier).updateGeneratedStoryPath(book.id, filePath);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Hikaye başarıyla oluşturuldu! Lütfen uygulamayı yeniden başlatın.')),
          );
          
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Hata'),
            content: Text(e.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Tamam'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = ref.watch(bookScannerProvider);
    final bookIndex = books.indexWhere((b) => b.id == widget.bookId);
    
    if (bookIndex == -1) {
      return Scaffold(
        appBar: AppBar(title: const Text('Book Not Found')),
        body: const Center(child: Text('This book was deleted.')),
      );
    }
    
    final book = books[bookIndex];

    return Scaffold(
      appBar: AppBar(
        title: Text(book.title),
        actions: [
          IconButton(
            tooltip: 'Kitabı Paylaş',
            icon: const Icon(Icons.share),
            onPressed: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Kitap paylaşılmak için paketleniyor...'),
                  duration: Duration(seconds: 1),
                ),
              );
              try {
                await BookSharingService.instance.exportBook(book);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Paylaşım sırasında hata: $e')),
                  );
                }
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: book.pageImagePaths.isEmpty
                ? const Center(child: Text('Taranmış sayfa yok.'))
                : GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: book.pageImagePaths.length,
                    itemBuilder: (context, index) {
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.file(
                            File(book.pageImagePaths[index]),
                            fit: BoxFit.cover,
                          ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: CircleAvatar(
                              backgroundColor: Colors.black54,
                              child: IconButton(
                                icon: const Icon(Icons.delete, color: Colors.white, size: 20),
                                onPressed: () {
                                  ref.read(bookScannerProvider.notifier).deletePage(book.id, index);
                                },
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 4,
                            left: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              color: Colors.black54,
                              child: Text(
                                'Sayfa ${index + 1}',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          if (_isGenerating)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(_statusText),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ElevatedButton.icon(
                onPressed: book.pageImagePaths.isEmpty ? null : _generateStory,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Yapay Zeka ile Hikaye Oluştur'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
