#!/usr/bin/env dart
/// Pre-warms audio assets by calling the ElevenLabs Sound Generation API
/// for every unique prompt found in story JSON files, then saves the
/// resulting MP3s under assets/audio/ and writes a manifest.json.
///
/// Usage:
///   dart run tools/prewarm_audio.dart
///
/// Requires ELEVENLABS_API_KEY in .env file.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

// ---------------------------------------------------------------------------
// Prompt extraction — mirrors the logic in the Flutter app
// ---------------------------------------------------------------------------

/// Mirrors SoundProfile.buildAmbiencePrompt() from story_models.dart.
String buildAmbiencePrompt(
  String variant,
  String primarySound,
  String texture, {
  String? secVariant,
  String? secPrimarySound,
}) {
  final base =
      '$variant $primarySound background ambience feeling $texture, '
      'continuous seamless ambient audio loop';
  if (secVariant == null || secPrimarySound == null) return base;
  return '$secVariant $secPrimarySound and $variant $primarySound '
      'background ambience feeling $texture, continuous seamless ambient audio loop';
}

/// Mirrors ElevenLabsService.fetchMusic().
String buildMusicPrompt(String theme) =>
    'background music theme $theme, cinematic instrumental loop';

/// Extracts all unique audio prompts from a story JSON map.
/// Returns a list of {prompt, type, durationSeconds} records.
List<_AudioPrompt> extractPrompts(Map<String, dynamic> storyJson) {
  final prompts = <String, _AudioPrompt>{};

  for (final sceneRaw in storyJson['scene_graph'] as List) {
    final scene = sceneRaw as Map<String, dynamic>;
    final sceneAudio = scene['scene_audio'] as Map<String, dynamic>;

    // --- Ambience ---
    final primary =
        sceneAudio['primary_ambience'] as Map<String, dynamic>;
    final sp = primary['sound_profile'] as Map<String, dynamic>;
    final secLayers = sceneAudio['secondary_layers'] as List? ?? [];

    String? secVariant, secPrimarySound;
    if (secLayers.isNotEmpty) {
      final secSp =
          (secLayers.first as Map<String, dynamic>)['sound_profile']
              as Map<String, dynamic>;
      secVariant = secSp['variant'] as String;
      secPrimarySound = secSp['primary_sound'] as String;
    }

    final ambiencePrompt = buildAmbiencePrompt(
      sp['variant'] as String,
      sp['primary_sound'] as String,
      sp['texture'] as String,
      secVariant: secVariant,
      secPrimarySound: secPrimarySound,
    );
    prompts.putIfAbsent(
      ambiencePrompt,
      () => _AudioPrompt(ambiencePrompt, 'ambience', 15.0),
    );

    // --- Music ---
    final musicLayer = sceneAudio['music_layer'] as Map<String, dynamic>?;
    if (musicLayer != null && (musicLayer['enabled'] as bool? ?? false)) {
      final theme = musicLayer['music_theme'] as String;
      final musicPrompt = buildMusicPrompt(theme);
      prompts.putIfAbsent(
        musicPrompt,
        () => _AudioPrompt(musicPrompt, 'music', 22.0),
      );
    }

    // --- SFX ---
    for (final aoRaw in scene['audio_opportunities'] as List? ?? []) {
      final ao = aoRaw as Map<String, dynamic>;
      final eventSummary = ao['event_summary'] as String;
      prompts.putIfAbsent(
        eventSummary,
        () => _AudioPrompt(eventSummary, 'sfx', 4.0),
      );
    }
  }

  return prompts.values.toList();
}

class _AudioPrompt {
  final String prompt;
  final String type;
  final double durationSeconds;
  const _AudioPrompt(this.prompt, this.type, this.durationSeconds);
}

// ---------------------------------------------------------------------------
// API call
// ---------------------------------------------------------------------------

Future<Uint8List> fetchAudio(
  Dio dio,
  String prompt,
  double durationSeconds,
) async {
  final clamped = durationSeconds.clamp(0.5, 22.0);
  print('  → POST /sound-generation ${prompt.substring(0, prompt.length.clamp(0, 60))}… (${clamped}s)');

  final response = await dio.post<dynamic>(
    '/sound-generation',
    data: {
      'text': prompt,
      'duration_seconds': clamped,
      'prompt_influence': 0.3,
    },
  );

  return Uint8List.fromList(response.data as List<int>);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

/// Reads a simple KEY=VALUE .env file and returns a map.
Map<String, String> _loadEnv(String path) {
  final file = File(path);
  if (!file.existsSync()) return {};
  final map = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final eq = trimmed.indexOf('=');
    if (eq < 0) continue;
    final key = trimmed.substring(0, eq).trim();
    var value = trimmed.substring(eq + 1).trim();
    if (value.startsWith("'") && value.endsWith("'")) {
      value = value.substring(1, value.length - 1);
    } else if (value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    map[key] = value;
  }
  return map;
}

Future<void> main() async {
  // Load .env manually (no Flutter dependency)
  final env = _loadEnv('.env');
  final apiKey = env['ELEVENLABS_API_KEY'] ?? '';
  if (apiKey.isEmpty) {
    stderr.writeln('ERROR: ELEVENLABS_API_KEY not set in .env');
    exit(1);
  }
  print('API key: ${apiKey.substring(0, 8)}…');

  final dio = Dio(BaseOptions(
    baseUrl: 'https://api.elevenlabs.io/v1',
    headers: {
      'xi-api-key': apiKey,
      'Content-Type': 'application/json',
      'Accept': 'audio/mpeg',
    },
    responseType: ResponseType.bytes,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 60),
  ));

  // Output directory
  final projectDir = Directory.current;
  final audioDir = Directory('${projectDir.path}/assets/audio');
  if (!await audioDir.exists()) {
    await audioDir.create(recursive: true);
  }

  // Scan story files
  final storiesDir = Directory('${projectDir.path}/assets/stories');
  final allPrompts = <_AudioPrompt>[];
  final seen = <String>{};

  await for (final entity in storiesDir.list()) {
    if (entity is File && entity.path.endsWith('.json')) {
      final name = entity.uri.pathSegments.last;
      if (name == 'manifest.json') continue; // skip story manifest
      print('\n📖 Scanning $name…');
      final jsonStr = await entity.readAsString();
      final storyJson =
          jsonDecode(jsonStr) as Map<String, dynamic>;
      final prompts = extractPrompts(storyJson);
      for (final p in prompts) {
        if (seen.add(p.prompt)) {
          allPrompts.add(p);
          print('  + ${p.type}: "${p.prompt.substring(0, p.prompt.length.clamp(0, 60))}…"');
        }
      }
    }
  }

  print('\n🎵 Total unique prompts: ${allPrompts.length}');
  print('   Ambience: ${allPrompts.where((p) => p.type == 'ambience').length}');
  print('   Music:    ${allPrompts.where((p) => p.type == 'music').length}');
  print('   SFX:      ${allPrompts.where((p) => p.type == 'sfx').length}');

  // Fetch & save
  final manifest = <String, String>{}; // sha1 → prompt
  var generated = 0;
  var skipped = 0;

  for (final ap in allPrompts) {
    final sha1Key = sha1.convert(utf8.encode(ap.prompt)).toString();
    final outFile = File('${audioDir.path}/$sha1Key.mp3');

    // Skip if already exists
    if (await outFile.exists()) {
      print('  ✓ Already cached: $sha1Key (${ap.type})');
      manifest[sha1Key] = ap.prompt;
      skipped++;
      continue;
    }

    try {
      final bytes = await fetchAudio(dio, ap.prompt, ap.durationSeconds);
      await outFile.writeAsBytes(bytes, flush: true);
      manifest[sha1Key] = ap.prompt;
      generated++;
      print('  ✓ Saved: $sha1Key (${bytes.length} bytes, ${ap.type})');
    } catch (e) {
      stderr.writeln('  ✗ FAILED: $sha1Key (${ap.type}) — $e');
    }
  }

  // Write manifest
  final manifestFile = File('${audioDir.path}/manifest.json');
  final manifestJson = const JsonEncoder.withIndent('  ')
      .convert(manifest.map((k, v) => MapEntry(k, v)));
  await manifestFile.writeAsString(manifestJson, flush: true);

  print('\n✅ Done! Generated: $generated, Skipped (cached): $skipped');
  print('   Manifest: ${manifestFile.path}');
  print('   Audio dir: ${audioDir.path}');
}
