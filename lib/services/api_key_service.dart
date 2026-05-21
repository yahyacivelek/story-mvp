import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

class ApiKeyService {
  static final ApiKeyService instance = ApiKeyService._();
  ApiKeyService._();

  String _geminiApiKey = '';
  String _elevenLabsApiKey = '';

  String get geminiApiKey => _geminiApiKey;
  String get elevenlabsApiKey => _elevenLabsApiKey;

  Future<void> initialize() async {
    // 1. Düşük öncelik: .env fallback (Eğer .env yüklendiyse ve hata vermediyse)
    if (dotenv.isInitialized) {
      _geminiApiKey = dotenv.env['GEMINI_API_KEY'] ?? '';
      _elevenLabsApiKey = dotenv.env['ELEVENLABS_API_KEY'] ?? '';
    }

    // 2. Orta öncelik: --dart-define veya const String.fromEnvironment
    const envGemini = String.fromEnvironment('GEMINI_API_KEY');
    if (envGemini.isNotEmpty) _geminiApiKey = envGemini;

    const envEleven = String.fromEnvironment('ELEVENLABS_API_KEY');
    if (envEleven.isNotEmpty) _elevenLabsApiKey = envEleven;

    // 3. Yüksek öncelik: Lokal cihaz private storage (Kullanıcı tarafından uygulama içinden girilen)
    try {
      final file = await _getLocalFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        
        if (data.containsKey('GEMINI_API_KEY') && data['GEMINI_API_KEY'].toString().isNotEmpty) {
          _geminiApiKey = data['GEMINI_API_KEY'];
        }
        if (data.containsKey('ELEVENLABS_API_KEY') && data['ELEVENLABS_API_KEY'].toString().isNotEmpty) {
          _elevenLabsApiKey = data['ELEVENLABS_API_KEY'];
        }
      }
    } catch (e) {
      debugPrint('ApiKeyService: Failed to read local keys: $e');
    }
  }

  Future<void> saveKeys({required String geminiKey, required String elevenLabsKey}) async {
    _geminiApiKey = geminiKey;
    _elevenLabsApiKey = elevenLabsKey;
    
    try {
      final file = await _getLocalFile();
      final data = {
        'GEMINI_API_KEY': geminiKey,
        'ELEVENLABS_API_KEY': elevenLabsKey,
      };
      await file.writeAsString(jsonEncode(data));
      debugPrint('ApiKeyService: Saved keys to local secure storage.');
    } catch (e) {
      debugPrint('ApiKeyService: Failed to save local keys: $e');
    }
  }

  Future<File> _getLocalFile() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File(path.join(directory.path, 'secure_keys.json'));
    return file;
  }
}
