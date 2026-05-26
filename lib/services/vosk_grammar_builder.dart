import '../models/story_models.dart';

/// Builds a per-scene vocabulary list for Vosk grammar-constrained recognition.
///
/// Vosk's grammar mode restricts the recognizer to a closed word-set passed as
/// a JSON array of strings, e.g. `["bay", "küt", "çarpar", "[unk]"]`.
/// This yields near-zero-latency results, lower CPU usage, and much higher
/// accuracy because the decoder search space is dramatically reduced.
///
/// The vocabulary is assembled from:
///   1. All primary/secondary keywords in the active scene's entry_cues and
///      exit_cues (scene transition triggers).
///   2. All trigger_primary_keywords and trigger_secondary_keywords from every
///      AudioOpportunity in the active scene.
///   3. Trigger anchor phrases (split into individual words).
///   4. All words from the page full-texts belonging to the active scene
///      (keeps karaoke read-progress working).
///   5. The special token `"[unk]"` which tells Vosk to emit an unknown-word
///      placeholder instead of ignoring out-of-vocabulary audio entirely.
///      Without it the recognizer can silently produce empty results.
class VoskGrammarBuilder {
  VoskGrammarBuilder._();

  /// Returns a deduplicated, lowercase word list suitable for passing to
  /// [VoskFlutterPlugin.createRecognizer] or [Recognizer.setGrammar].
  ///
  /// Always includes `"[unk]"` so the recognizer keeps running even when
  /// speech falls outside the vocabulary.
  static List<String> buildForScene({
    required Scene scene,
    required List<StoryPage> allPages,
  }) {
    final words = <String>{};

    // 1. Scene activation cues (entry + exit keywords).
    for (final cue in [
      ...scene.sceneActivation.entryCues,
      ...scene.sceneActivation.exitCues,
    ]) {
      for (final kw in [...cue.primaryKeywords, ...cue.secondaryKeywords]) {
        _addPhrase(kw, words);
      }
    }

    // 2. AudioOpportunity trigger keywords + anchor phrases.
    for (final ao in scene.audioOpportunities) {
      for (final kw in [
        ...ao.triggerPrimaryKeywords,
        ...ao.triggerSecondaryKeywords,
      ]) {
        _addPhrase(kw, words);
      }
      _addPhrase(ao.triggerAnchor.value, words);
    }

    // 3. Page full-texts for the active scene (karaoke alignment).
    final pageNums = scene.pages.toSet();
    for (final page in allPages) {
      if (!pageNums.contains(page.pageNumber)) continue;
      _addPhrase(page.fullText, words);
    }

    // Vosk grammar MUST include [unk] to handle out-of-vocabulary audio
    // gracefully; without it the recognizer may emit empty strings on
    // speech it cannot match.
    words.add('[unk]');

    return words.toList();
  }

  /// Builds the initial "full-story" vocabulary used during model warm-up
  /// before the first scene is known (covers all scenes in the story).
  static List<String> buildForStory(StoryData data) {
    final words = <String>{};
    for (final scene in data.sceneGraph) {
      for (final w in buildForScene(scene: scene, allPages: data.pages)) {
        words.add(w);
      }
    }
    words.add('[unk]');
    return words.toList();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  static final _wordRe = RegExp(r"[\w\u00C0-\u024F']+", unicode: true);

  static void _addPhrase(String phrase, Set<String> out) {
    for (final m in _wordRe.allMatches(phrase.toLowerCase())) {
      final w = m.group(0)!;
      if (w.isNotEmpty) out.add(w);
    }
  }
}
