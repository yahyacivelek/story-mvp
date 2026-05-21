import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:image/image.dart' as img;

import '../models/scanned_book_model.dart';
import 'api_key_service.dart';
import 'story_validator.dart';

class GeminiAnalyzerService {
  static final GeminiAnalyzerService instance = GeminiAnalyzerService._();
  GeminiAnalyzerService._();

  /// Analyzes a scanned book and returns the raw JSON string if successful.
  Future<String?> generateStoryJson(ScannedBook book, {void Function(String)? onProgress}) async {
    try {
      final apiKey = ApiKeyService.instance.geminiApiKey;
      if (apiKey.isEmpty) {
        throw Exception('Gemini API Key bulunamadı. Lütfen Ayarlar panelinden ekleyin.');
      }

      onProgress?.call('Initializing Gemini 2.5 Flash...');
      final model = GenerativeModel(
        model: 'gemini-2.5-flash',
        apiKey: apiKey,
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          // We prompt it to follow the schema strictly instead of passing responseSchema object
          // since the JSON schema is very complex with $defs.
        ),
      );

      onProgress?.call('Loading and compressing images...');
      final List<DataPart> imageParts = [];
      for (int i = 0; i < book.pageImagePaths.length; i++) {
        final path = book.pageImagePaths[i];
        final bytes = await _compressImage(path);
        if (bytes != null) {
          imageParts.add(DataPart('image/jpeg', bytes));
        }
      }

      onProgress?.call('Reading story schema...');
      final schemaStr = await rootBundle.loadString('assets/schemas/story_schema.json');

      final prompt = '''
You are an expert multimodal children's storybook narrative analyzer and cinematic bedtime audio planner.

You specialize in:
- OCR extraction
- illustration understanding
- multimodal narrative analysis
- cinematic scene segmentation
- immersive bedtime audio orchestration
- realtime narrative synchronization
- layered ambience planning
- child-friendly sound design
- structured semantic audio tagging
- scene runtime planning

You are given multiple photographed pages from a children's picture book.

The pages may:
- contain page numbers
- contain no page numbers
- be partially visible
- contain illustrations more important than text
- contain story continuity across pages

Your task is NOT only OCR.

Your task is to analyze the ENTIRE BOOK as a unified narrative experience similar to:
- an animated movie
- a cinematic read-along
- a bedtime storytelling soundtrack plan

The output will power:
- realtime read-along systems
- speech-following systems
- scene orchestration engines
- adaptive ambience playback
- voice-triggered sound effects
- offline mobile applications
- semantic sound retrieval systems
- sound asset caching systems

PRIMARY GOAL:

Transform the photographed book pages into:
- ordered pages
- narrative scenes
- scene transitions
- scene runtime metadata
- layered ambience plans
- emotional pacing
- reusable sound orchestration metadata

CORE EXPERIENCE GOALS:
- The parent's voice must remain primary.
- Audio should enhance storytelling without distraction.
- The experience should feel:
  - warm
  - magical
  - cinematic
  - emotionally supportive
  - calm
  - immersive
- Avoid overstimulation.
- Avoid noisy or chaotic sound design.

PAGE ORDERING RULES:

Determine page order using:
1. visible page numbers if available
2. capture order if page numbers are missing
3. narrative continuity inference if needed

Return confidence estimates for page ordering.

SCENE SEGMENTATION RULES:

The book should be divided into narrative scenes.

Scenes should be determined using BOTH:
- text
- illustrations

A scene may span multiple pages.

A scene should represent:
- a coherent environment
- emotional continuity
- narrative continuity
- ambience continuity

Examples:
- magical forest journey
- nighttime bedroom
- entering cave
- storm at sea
- village marketplace
- calm ending

Scene duration should generally feel stable and cinematic rather than rapidly changing.

SCENE RUNTIME RULES:

Scenes are runtime states.

A scene lifecycle may be:
- inactive
- candidate
- active
- fading_out
- completed

Scenes should contain stable activation and transition cues suitable for realtime speech-following systems.

Scene activation may occur using:
- manual activation
- fuzzy speech matching
- hybrid approaches

Scene transitions should generally feel gradual and cinematic rather than abrupt.

Scene transitions may:
- fade
- crossfade
- evolve emotionally
- evolve ambience gradually
- continue previous ambience partially

Examples:
- forest_day -> forest_evening
- calm_room -> stormy_night
- magical_wonder -> suspense

SCENE ACTIVATION RULES:

Each scene should include:
- entry cues
- optional exit cues
- activation trigger structures
- confidence-friendly speech anchors
- likely next scene prediction

Entry cues should:
- prefer short stable phrases
- tolerate paraphrasing
- avoid fragile exact sentence matching

Scene activation should prioritize:
- semantic meaning
- narrative progression
- environmental changes
- emotional transitions

SCENE AUDIO RULES:

Each scene may contain:
- one primary ambience layer
- optional secondary ambience details
- optional emotional music layer
- optional voice-triggered event sounds
- optional animal presence sounds

Examples:
- forest ambience
- cave dripping
- fireplace crackling
- ocean waves
- nighttime crickets
- magical sparkles
- soft owl hoots

Scene ambience should often persist across the entire scene.

Scene audio may:
- continue from previous scenes
- evolve gradually
- fade between scenes
- darken or brighten emotionally

IMMERSION RULES:

The experience should contain enough ambient and emotional detail to feel immersive and cinematic while remaining child-friendly.

Small subtle audio moments are encouraged.

Do not limit audio opportunities only to major events.

Ambient layers are extremely important.

ANIMAL SOUND RULES:

Animal sounds are encouraged whenever animals are:
- visually important
- narratively important
- environmentally relevant

Prefer child-friendly animal sounds:
- bird chirps
- owl hoots
- sleepy bear breathing
- frog croaks
- soft lion roar
- playful monkey chatter
- distant whale calls

Avoid harsh realistic predator aggression unless explicitly required by the story.

TRIGGER RULES:

Voice-triggered events should:
- use stable trigger phrases
- tolerate paraphrasing
- avoid collisions with nearby triggers
- be scoped to active scenes
- support fuzzy speech matching

Trigger anchors should:
- prefer nouns or short phrases
- avoid long sentences
- remain robust during read-aloud narration

Ambience layers should usually activate from scene start rather than keyword triggers.

SOUND REPRESENTATION RULES:

All sound outputs must be:
- cache-friendly
- reusable
- deterministic
- semantically consistent

Avoid creative prose descriptions.

Prefer canonical semantic sound identifiers.

RUNTIME MODEL ASSUMPTIONS:

Assume runtime maintains:
- current page
- current scene
- reading progression
- active ambience layers
- scene confidence state

Assume:
- scenes may be started manually
- scenes may transition automatically using fuzzy voice matching
- runtime may preload likely next-scene ambience

CRITICAL SCHEMA CONFORMANCE RULES:

You MUST strictly conform to the allowed enums defined in the JSON schema. Pay close attention to these fields and NEVER use values outside the specified lists:

1. `ambience_sound_profile/variant`:
   - Allowed enums: "soft", "warm", "gentle", "cozy", "light", "mysterious", "playful"
   - Crucial: DO NOT use "calm", "medium", or any other value outside this list.

2. `sfx_sound_profile/variant`:
   - Allowed enums: "soft", "playful", "warm", "gentle", "mysterious", "light", "calm", "cozy"
   - Crucial: DO NOT use "medium", "high", "low", or any other value outside this list.

3. `scene_transition/audio_continuity`:
   - Allowed enums: "continue", "evolve", "replace"
   - Crucial: DO NOT use "fade_out", "fade", "crossfade", or any other value outside this list.

4. `scene_transition/transition_style`:
   - Allowed enums: "fade", "crossfade", "darken", "brighten", "hard_cut", "none"

5. `ambience_sound_profile/primary_sound`:
   - Allowed enums: "forest", "rain", "wind", "ocean", "night_crickets", "birds", "fireplace", "village_day", "cave_drip", "garden_breeze", "magic_ambience", "other"

6. `sfx_sound_profile/primary_sound`:
   - Allowed enums: "bird_chirp", "owl_hoot", "frog_croak", "lion_roar_soft", "wolf_howl_soft", "monkey_chatter", "bear_breathing", "cat_purr", "dog_bark_soft", "horse_gallop", "duck_quack", "whale_call", "bee_buzz", "footsteps_grass", "footsteps_wood", "door_creak", "magic_chime", "magic_whoosh", "water_splash", "other"

7. `mood` & `scene_mood`:
   - Allowed enums: "cozy", "magical", "playful", "warm", "calm", "suspenseful", "adventurous", "mysterious"

8. `scene_audio/music_layer/music_theme`:
   - Allowed enums: "wonder", "calm", "cozy", "mystery", "adventure", "comfort", "sleepy"
   - Crucial: DO NOT use "playful" or any other value outside this list.

9. `audio_opportunity/layer_role`:
   - Allowed enums: "secondary_detail", "event", "animal_presence", "animal_vocalization", "emotional_music"
   - Crucial: DO NOT use "movement" or any other value outside this list.

OUTPUT RULES:
- Return ONLY valid JSON.
- No markdown.
- No explanations.
- No comments.
- Keep outputs compact.
- Prefer enums over free text where possible.

JSON schema:
$schemaStr
''';

      onProgress?.call('Analyzing with Gemini (this may take a minute)...');
      final content = [
        Content.multi([
          TextPart(prompt),
          ...imageParts,
        ])
      ];

      final response = await model.generateContent(content);
      final rawText = response.text;
      
      if (rawText == null) throw Exception('No response from Gemini');

      // Clean up markdown formatting if the model still outputs it
      String cleanedJson = rawText.trim();
      if (cleanedJson.startsWith('```json')) {
        cleanedJson = cleanedJson.substring(7);
      }
      if (cleanedJson.startsWith('```')) {
        cleanedJson = cleanedJson.substring(3);
      }
      if (cleanedJson.endsWith('```')) {
        cleanedJson = cleanedJson.substring(0, cleanedJson.length - 3);
      }
      cleanedJson = cleanedJson.trim();

      onProgress?.call('Validating generated JSON...');
      await StoryValidator.init();
      // Validate using our existing StoryValidator
      final validatedMap = StoryValidator.decodeAndValidate(cleanedJson);
      
      onProgress?.call('Done!');
      return jsonEncode(validatedMap);

    } catch (e) {
      debugPrint('GeminiAnalyzerService Error: $e');
      rethrow;
    }
  }

  /// Compresses the image to save bandwidth and API limits. Max width 1024px.
  Future<Uint8List?> _compressImage(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    
    final bytes = await file.readAsBytes();
    img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    if (decoded.width > 1024) {
      decoded = img.copyResize(decoded, width: 1024);
    }
    
    // Encode to JPEG with 80% quality
    return Uint8List.fromList(img.encodeJpg(decoded, quality: 80));
  }
}
