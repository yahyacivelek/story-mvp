import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_key_service.dart';
import '../services/book_scanner_service.dart';
import 'book_editor_screen.dart';

class BookCreatorScreen extends ConsumerWidget {
  const BookCreatorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final books = ref.watch(bookScannerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanner Studio'),
        actions: [
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
              itemCount: books.length,
              itemBuilder: (context, index) {
                final book = books[index];
                return ListTile(
                  leading: book.pageImagePaths.isNotEmpty
                      ? Image.file(
                          File(book.pageImagePaths.first),
                          width: 50,
                          height: 50,
                          fit: BoxFit.cover,
                        )
                      : const Icon(Icons.book),
                  title: Text(book.title),
                  subtitle: Text('${book.pageImagePaths.length} sayfa - ${book.generatedStoryJsonPath != null ? "Analiz Edildi" : "Taslak"}'),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => BookEditorScreen(bookId: book.id),
                      ),
                    );
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () {
                      ref.read(bookScannerProvider.notifier).deleteBook(book.id);
                    },
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
