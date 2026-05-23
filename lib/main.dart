import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/story_screen.dart';
import 'services/api_key_service.dart';
import 'services/audio_cache_service.dart';
import 'services/story_validator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable();
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    debugPrint('[main] .env file not found, relying on local config and dart-define.');
  }
  await ApiKeyService.instance.initialize();
  
  // Pre-warm the story validator schema
  try {
    await StoryValidator.init();
    debugPrint('[main] StoryValidator schema initialized.');
  } catch (e) {
    debugPrint('[main] Failed to pre-warm StoryValidator schema: $e');
  }

  // Pre-warm the audio cache from bundled assets first (works on every
  // platform including Chrome debug — no IndexedDB dependency).
  final assetLoaded = await AudioCacheService.instance.preloadFromAssets();
  debugPrint('[main] Audio cache from assets: $assetLoaded entries');

  // Then load any additional entries from persistent storage (IndexedDB /
  // filesystem) that aren't already in memory from assets.
  final loaded = await AudioCacheService.instance.preloadAll();
  debugPrint('[main] Audio cache pre-warmed: $loaded entries');

  runApp(const ProviderScope(child: StoryApp()));
}

class StoryApp extends StatelessWidget {
  const StoryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "The Wanderer's Chronicle",
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: const StoryScreen(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    const seedColor = Color(0xFF7B8CDE);
    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: 'Georgia',
      textTheme: const TextTheme(
        bodyLarge: TextStyle(fontSize: 18, height: 1.9, letterSpacing: 0.2),
        bodyMedium: TextStyle(fontSize: 15, height: 1.6),
        bodySmall: TextStyle(fontSize: 13),
      ),
    );
  }
}
