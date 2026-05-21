import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/scanned_book_model.dart';
import '../services/api_key_service.dart';
import '../services/book_scanner_service.dart';
import '../services/book_sharing_service.dart';
import 'book_editor_screen.dart';

class BookCreatorScreen extends ConsumerWidget {
  const BookCreatorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final books = ref.watch(bookScannerProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanner Studio'),
        actions: [
          IconButton(
            tooltip: 'Kitap İçe Aktar (.story)',
            icon: const Icon(Icons.file_upload),
            onPressed: () async {
              try {
                final result = await FilePicker.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['story', 'zip'],
                );

                if (result != null && result.files.single.path != null) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Row(
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            ),
                            SizedBox(width: 16),
                            Text('Kitap içe aktarılıyor...'),
                          ],
                        ),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }

                  final file = File(result.files.single.path!);
                  final importedBook = await BookSharingService.instance.importBookFile(file);
                  await ref.read(bookScannerProvider.notifier).importScannedBook(importedBook);

                  if (context.mounted) {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        backgroundColor: Colors.green,
                        content: Text('"${importedBook.title}" başarıyla içe aktarıldı!'),
                      ),
                    );
                  }
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('İçe Aktarma Hatası'),
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
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _showApiKeyDialog(context),
          ),
        ],
      ),
      body: books.isEmpty
          ? const Center(
              child: Text(
                'Henüz taranmış kitap yok.\nYeni bir kitap taramak için + butonuna basın.',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: books.length,
              itemBuilder: (context, index) {
                final book = books[index];
                final hasStory = book.generatedStoryJsonPath != null;

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => BookEditorScreen(bookId: book.id),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: book.pageImagePaths.isNotEmpty
                                ? Image.file(
                                    File(book.pageImagePaths.first),
                                    width: 64,
                                    height: 64,
                                    fit: BoxFit.cover,
                                  )
                                : Container(
                                    width: 64,
                                    height: 64,
                                    color: colorScheme.primaryContainer,
                                    child: Icon(
                                      Icons.book,
                                      color: colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  book.title,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: colorScheme.secondaryContainer,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        '${book.pageImagePaths.length} Sayfa',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: colorScheme.onSecondaryContainer,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: hasStory
                                            ? Colors.green.withValues(alpha: 0.15)
                                            : Colors.amber.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        hasStory ? 'Analiz Edildi' : 'Taslak',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: hasStory ? Colors.green : Colors.amber[800],
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'Kitabı Paylaş',
                            icon: const Icon(Icons.share, color: Colors.blueAccent),
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
                          IconButton(
                            tooltip: 'Kitabı Sil',
                            icon: const Icon(Icons.delete, color: Colors.redAccent),
                            onPressed: () {
                              _showDeleteConfirmDialog(context, ref, book);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final titleController = TextEditingController();
          final title = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Kitap Adı'),
              content: TextField(
                controller: titleController,
                decoration: const InputDecoration(hintText: 'Örn: Keloğlan Masalları'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('İptal'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, titleController.text),
                  child: const Text('Tamam'),
                ),
              ],
            ),
          );

          if (title != null && title.isNotEmpty) {
            final newBook = await ref.read(bookScannerProvider.notifier).scanNewBook(title);
            if (newBook != null && context.mounted) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BookEditorScreen(bookId: newBook.id),
                ),
              );
            }
          }
        },
        child: const Icon(Icons.document_scanner),
      ),
    );
  }

  Future<void> _showDeleteConfirmDialog(BuildContext context, WidgetRef ref, ScannedBook book) async {
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kitabı Sil'),
        content: Text('"${book.title}" kitabını silmek istediğinize emin misiniz? Bu işlem geri alınamaz.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              ref.read(bookScannerProvider.notifier).deleteBook(book.id);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Kitap başarıyla silindi.')),
              );
            },
            child: const Text('Sil'),
          ),
        ],
      ),
    );
  }

  Future<void> _showApiKeyDialog(BuildContext context) async {
    final geminiController = TextEditingController(text: ApiKeyService.instance.geminiApiKey);
    final elevenLabsController = TextEditingController(text: ApiKeyService.instance.elevenlabsApiKey);
    bool obscureGemini = true;
    bool obscureElevenLabs = true;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('API Ayarları'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: geminiController,
                      obscureText: obscureGemini,
                      decoration: InputDecoration(
                        labelText: 'Gemini API Key',
                        suffixIcon: IconButton(
                          icon: Icon(obscureGemini ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => obscureGemini = !obscureGemini),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: elevenLabsController,
                      obscureText: obscureElevenLabs,
                      decoration: InputDecoration(
                        labelText: 'ElevenLabs API Key',
                        suffixIcon: IconButton(
                          icon: Icon(obscureElevenLabs ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => obscureElevenLabs = !obscureElevenLabs),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('İptal'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await ApiKeyService.instance.saveKeys(
                      geminiKey: geminiController.text.trim(),
                      elevenLabsKey: elevenLabsController.text.trim(),
                    );
                    if (context.mounted) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('API anahtarları başarıyla kaydedildi!')),
                      );
                    }
                  },
                  child: const Text('Kaydet'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
