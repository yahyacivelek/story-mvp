import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/story_screen.dart';
import 'services/audio_cache_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');

  // Pre-warm the audio cache: loads all previously generated audio
  // from persistent storage into memory so debug runs never hit the API.
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
