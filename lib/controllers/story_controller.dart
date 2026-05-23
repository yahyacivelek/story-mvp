import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../models/story_models.dart';
import '../services/speech_service.dart';
import '../utils/fuzzy_matcher.dart';
import 'audio_controller.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class StoryState {
  final StoryManifest? manifest;
  final StoryEntry? currentStoryEntry;
  final StoryData? storyData;
  final int activeSceneIndex;
  final bool isLoading;
  final String? error;
  final bool isListening;
  final String lastHeardText;

  const StoryState({
    this.manifest,
    this.currentStoryEntry,
    this.storyData,
    this.activeSceneIndex = 0,
    this.isLoading = true,
    this.error,
    this.isListening = false,
    this.lastHeardText = '',
  });

  Scene? get activeScene =>
      storyData != null && storyData!.sceneGraph.isNotEmpty
          ? storyData!.sceneGraph[activeSceneIndex]
          : null;

  List<StoryPage> get activePagesContent {
    if (storyData == null || activeScene == null) return [];
    final pageNums = activeScene!.pages.toSet();
    return storyData!.pages
        .where((p) => pageNums.contains(p.pageNumber))
        .toList()
      ..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));
  }

  StoryState copyWith({
    StoryManifest? manifest,
    StoryEntry? currentStoryEntry,
    StoryData? storyData,
    int? activeSceneIndex,
    bool? isLoading,
    String? error,
    bool? isListening,
    String? lastHeardText,
  }) {
    return StoryState(
      manifest: manifest ?? this.manifest,
      currentStoryEntry: currentStoryEntry ?? this.currentStoryEntry,
      storyData: storyData ?? this.storyData,
      activeSceneIndex: activeSceneIndex ?? this.activeSceneIndex,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      isListening: isListening ?? this.isListening,
      lastHeardText: lastHeardText ?? this.lastHeardText,
    );
  }
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

class StoryController extends StateNotifier<StoryState> {
  StoryController(this._ref) : super(const StoryState()) {
    _init();
  }

  final Ref _ref;
  final SpeechService _speech = SpeechService.instance;
  StreamSubscription<String>? _speechSub;

  /// Rolling transcript window — keeps last ~120 words for matching.
  /// Increased from 60 to handle longer pages where exit cues are at the end.
  final List<String> _transcriptBuffer = [];
  static const int _bufferWordLimit = 120;

  /// Cooldown per audio opportunity: stores last trigger time by id.
  final Map<String, DateTime> _lastTriggered = {};

  /// Timestamp of last scene transition — prevents rapid re-transitions.
  DateTime? _lastTransitionAt;

  /// Minimum seconds between automatic scene transitions.
  /// Reduced to 5s for faster-paced storytelling.
  static const int _transitionCooldownSeconds = 5;

  Future<void> _init() async {
    try {
      final manifestJson =
          await rootBundle.loadString('assets/stories/manifest.json');
      final manifest = StoryManifest.fromJsonString(manifestJson);

      // Fetch local generated books (not supported on web)
      final localStories = <StoryEntry>[];
      if (!kIsWeb) {
        final appDocDir = await getApplicationDocumentsDirectory();
        final booksDir = Directory(path.join(appDocDir.path, 'scanned_books'));
        if (await booksDir.exists()) {
          final indexFile = File(path.join(booksDir.path, 'books_index.json'));
          if (await indexFile.exists()) {
            try {
               final content = await indexFile.readAsString();
               final List<dynamic> jsonList = jsonDecode(content);
               for(var item in jsonList) {
                 if (item['generatedStoryJsonPath'] != null) {
                   localStories.add(StoryEntry(
                     id: item['id'],
                     title: item['title'],
                     language: 'tr', // Default for generated
                     assetPath: item['generatedStoryJsonPath'],
                     isLocal: true,
                   ));
                 }
               }
            } catch(e) {
               debugPrint('Error reading local stories index: $e');
            }
          }
        }
      }

      final combinedManifest = StoryManifest(
        stories: [...manifest.stories, ...localStories]
      );

      state = state.copyWith(manifest: combinedManifest);

      // 2. Load the first story automatically.
      if (combinedManifest.stories.isNotEmpty) {
        await loadStory(combinedManifest.stories.first);
      } else {
        state = state.copyWith(isLoading: false, error: 'No stories found');
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Loads a specific story by its [StoryEntry] and resets all state.
  Future<void> loadStory(StoryEntry entry) async {
    // Stop current audio and speech before switching.
    await stopListening();
    await _ref.read(audioControllerProvider.notifier).stopAmbience();
    await _ref.read(audioControllerProvider.notifier).stopMusic();

    state = state.copyWith(
      currentStoryEntry: entry,
      isLoading: true,
      error: null,
      activeSceneIndex: 0,
    );

    try {
      final jsonString = (!kIsWeb && entry.isLocal)
          ? await File(entry.assetPath).readAsString()
          : await rootBundle.loadString(entry.assetPath);
      final data = StoryData.fromJsonString(jsonString);

      state = state.copyWith(
        storyData: data,
        isLoading: false,
        activeSceneIndex: 0,
      );

      if (data.sceneGraph.isNotEmpty) {
        final firstScene = data.sceneGraph.first;
        await _ref
            .read(audioControllerProvider.notifier)
            .startSceneAudio(firstScene);
      }

      // Start listening in the story's language.
      await startListening(languageCode: data.book.language);
      debugPrint('[StoryController] Loaded story: ${entry.title} (lang: ${data.book.language})');
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  // -------------------------------------------------------------------------
  // Manual scene selection (sidebar tap)
  // -------------------------------------------------------------------------

  Future<void> selectScene(int index) async {
    final data = state.storyData;
    if (data == null || index >= data.sceneGraph.length) return;
    if (index == state.activeSceneIndex) return;

    _transitionToScene(index);
  }

  // -------------------------------------------------------------------------
  // Speech listening
  // -------------------------------------------------------------------------

  Future<void> startListening({String languageCode = 'en'}) async {
    await _ref
        .read(audioControllerProvider.notifier)
        .setSpeechCaptureDucking(true);
    final ok = await _speech.startListening(languageCode: languageCode);
    if (!ok) {
      await _ref
          .read(audioControllerProvider.notifier)
          .setSpeechCaptureDucking(false);
      return;
    }

    state = state.copyWith(isListening: true);

    _speechSub = _speech.wordStream.listen(_onWords);
    debugPrint('[StoryController] speech listening started');
  }

  Future<void> stopListening() async {
    await _speech.stopListening();
    await _ref
        .read(audioControllerProvider.notifier)
        .setSpeechCaptureDucking(false);
    await _speechSub?.cancel();
    _speechSub = null;
    state = state.copyWith(isListening: false);
  }

  // -------------------------------------------------------------------------
  // Core matching logic
  // -------------------------------------------------------------------------

  void _onWords(String chunk) {
    // Accumulate into rolling buffer.
    final newWords = chunk.split(' ').where((w) => w.isNotEmpty).toList();
    _transcriptBuffer.addAll(newWords);
    if (_transcriptBuffer.length > _bufferWordLimit) {
      final removedCount = _transcriptBuffer.length - _bufferWordLimit;
      _transcriptBuffer.removeRange(0, removedCount);
    }

    final transcript = _transcriptBuffer.join(' ');
    state = state.copyWith(lastHeardText: chunk);

    debugPrint(
      '[StoryController] Heard: "${chunk.substring(0, chunk.length.clamp(0, 40))}..." '
      'bufferSize=${_transcriptBuffer.length}/${_bufferWordLimit}',
    );

    final data = state.storyData;
    if (data == null) return;

    // 1. Try to match audio opportunities in the active scene first.
    _matchAudioOpportunities(transcript, data);

    // 2. Try to advance to the next scene.
    _matchSceneTransition(transcript, data);
  }

  void _matchAudioOpportunities(String transcript, StoryData data) {
    final scene = state.activeScene;
    if (scene == null) return;

    for (final ao in scene.audioOpportunities) {
      // Cooldown check. Speech-to-text emits the same phrase as several
      // growing partial-result chunks (e.g. "tepedeki" → "tepedeki yaprak" →
      // "tepedeki yaprakları yemeye"), so without a floor every keyword-hit
      // partial would re-fire the same SFX several times per second.
      // We enforce a minimum 8-second floor on top of whatever the JSON
      // specifies, so a single utterance only triggers the SFX once.
      const minCooldownSeconds = 8;
      final cooldown = ao.triggerCooldownSeconds > minCooldownSeconds
          ? ao.triggerCooldownSeconds
          : minCooldownSeconds;
      final last = _lastTriggered[ao.id];
      if (last != null &&
          DateTime.now().difference(last).inSeconds < cooldown) {
        continue;
      }

      // Anchor is checked literally below — don't add it to primary keywords
      // or it inflates maxPoints with a phrase that STT often misrecognises,
      // making it harder for individual keyword matches to reach the threshold.
      final primary = [...ao.triggerPrimaryKeywords];
      final secondary = [
        ...ao.triggerSecondaryKeywords,
        ao.eventSummary.toLowerCase(),
      ];

      // Exact anchor phrase hit OR fuzzy keyword match.
      final anchorHit =
          transcript.contains(ao.triggerAnchor.value.toLowerCase());

      // Threshold 0.28: allows 1-of-3 primary keyword matches (2/6 ≈ 0.33)
      // to trigger while still requiring meaningful signal.
      final keywordHit = FuzzyMatcher.matches(
        transcript: transcript,
        primaryKeywords: primary,
        secondaryKeywords: secondary,
        threshold: 0.28,
      );

      debugPrint(
        '[StoryController] AO ${ao.id}: anchor=$anchorHit keyword=$keywordHit '
        'primary=$primary',
      );

      if (anchorHit || keywordHit) {
        debugPrint('[StoryController] AudioOpportunity triggered: ${ao.id}');
        _lastTriggered[ao.id] = DateTime.now();

        // Play the SFX.
        _ref.read(audioControllerProvider.notifier).playSfx(ao);

        // If trigger_once_per_scene, remove from further matching this session
        // by marking a far-future cooldown.
        if (ao.triggerOncePerScene) {
          _lastTriggered[ao.id] =
              DateTime.now().add(const Duration(hours: 24));
        }
      }
    }
  }

  void _matchSceneTransition(String transcript, StoryData data) {
    final scenes = data.sceneGraph;
    final currentScene = state.activeScene;
    if (currentScene == null) return;
    final transition = currentScene.sceneTransition;

    // No next scene — end of story.
    if (transition.nextSceneId == 'none') return;

    // Enforce cooldown between automatic transitions.
    if (_lastTransitionAt != null) {
      final secondsSinceLast = DateTime.now().difference(_lastTransitionAt!).inSeconds;
      if (secondsSinceLast < _transitionCooldownSeconds) {
        debugPrint(
          '[StoryController] Scene transition blocked: cooldown active '
          '(${secondsSinceLast}s / ${_transitionCooldownSeconds}s)',
        );
        return;
      }
    }

    // Find the next scene by its scene_id (not just index + 1).
    final nextIndex = scenes.indexWhere(
        (s) => s.sceneId == transition.nextSceneId);
    if (nextIndex < 0) {
      debugPrint(
        '[StoryController] Scene transition blocked: next scene "${transition.nextSceneId}" not found',
      );
      return;
    }

    final nextScene = scenes[nextIndex];

    // Build keyword lists from structured exit_cues + entry_cues in JSON.
    final exitKeywords = _cueKeywordsForScene(currentScene, isExit: true);
    final entryKeywords = _cueKeywordsForScene(nextScene, isExit: false);

    debugPrint(
      '[StoryController] Scene "${currentScene.sceneId}" → "${nextScene.sceneId}": '
      'exitPrimary=${exitKeywords.primary}, exitSecondary=${exitKeywords.secondary} | '
      'entryPrimary=${entryKeywords.primary}, entrySecondary=${entryKeywords.secondary}',
    );

    // Evaluate exit and entry cues separately (OR). Combining them inflated
    // maxPoints so a single end-of-scene phrase (e.g. "severmiş") scored
    // ~0.14 against the next scene's 0.7 activation threshold — never firing.
    // 0.5 = one primary hit in a 2-keyword cue list (2/4), or two in a 4-keyword list.
    // Lowered from 0.6 to improve detection of partial cue matches.
    const transitionThreshold = 0.5;

    final exitScore = _cueKeywordsNonEmpty(exitKeywords)
        ? FuzzyMatcher.score(
            transcript: transcript,
            primaryKeywords: exitKeywords.primary,
            secondaryKeywords: exitKeywords.secondary,
          )
        : 0.0;
    final exitHit = exitScore >= transitionThreshold;

    final entryScore = _cueKeywordsNonEmpty(entryKeywords)
        ? FuzzyMatcher.score(
            transcript: transcript,
            primaryKeywords: entryKeywords.primary,
            secondaryKeywords: entryKeywords.secondary,
          )
        : 0.0;
    final entryHit = entryScore >= transitionThreshold;

    debugPrint(
      '[StoryController] Matching transcript: "${transcript.substring(0, transcript.length.clamp(0, 80))}..." '
      'exitScore=${exitScore.toStringAsFixed(2)} entryScore=${entryScore.toStringAsFixed(2)}',
    );

    if (exitHit || entryHit) {
      debugPrint(
        '[StoryController] Scene transition: ${currentScene.sceneId} → '
        '${nextScene.sceneId} (exit=$exitHit, entry=$entryHit, exitScore=${exitScore.toStringAsFixed(2)}, entryScore=${entryScore.toStringAsFixed(2)})',
      );
      _transitionToScene(nextIndex);
    }
  }

  bool _cueKeywordsNonEmpty(_Keywords k) =>
      k.primary.isNotEmpty || k.secondary.isNotEmpty;

  /// Builds keyword lists from a scene's structured exit_cues or entry_cues.
  ///
  /// Falls back to deriving keywords from page text when cues are empty.
  _Keywords _cueKeywordsForScene(Scene scene, {required bool isExit}) {
    final cues = isExit
        ? scene.sceneActivation.exitCues
        : scene.sceneActivation.entryCues;

    if (cues.isNotEmpty) {
      final primary = cues
          .expand((c) => c.primaryKeywords)
          .toList();
      final secondary = cues
          .expand((c) => c.secondaryKeywords)
          .toList();
      // Only return if keywords actually survived parsing; otherwise fall
      // through to text-derived fallback so the matcher isn't handed empties.
      if (primary.isNotEmpty || secondary.isNotEmpty) {
        return _Keywords(primary: primary, secondary: secondary);
      }
    }

    // Fallback: derive from last page text when no structured cues.
    final data = state.storyData!;
    final pageNums = scene.pages.toSet();
    final pages = data.pages
        .where((p) => pageNums.contains(p.pageNumber))
        .toList()
      ..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));

    final lastPageWords = pages.isNotEmpty
        ? pages.last.fullText
            .toLowerCase()
            .split(RegExp(r'\s+'))
            .where((w) => w.length > 4)
            .take(8)
            .toList()
        : <String>[];

    final summaryWords = scene.sceneSummary
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 3)
        .take(6)
        .toList();

    return _Keywords(primary: summaryWords, secondary: lastPageWords);
  }

  void _transitionToScene(int index) {
    final data = state.storyData!;
    final currentScene = state.activeScene!;
    final transition = currentScene.sceneTransition;
    final nextScene = data.sceneGraph[index];

    state = state.copyWith(activeSceneIndex: index);
    _lastTransitionAt = DateTime.now();
    // Clear transcript buffer on scene change to avoid re-triggering.
    _transcriptBuffer.clear();
    _lastTriggered.clear();

    // Use crossfade transition when the JSON specifies it.
    _ref
        .read(audioControllerProvider.notifier)
        .transitionToScene(nextScene, transition: transition);

  }

  @override
  void dispose() {
    _speechSub?.cancel();
    _speech.stopListening();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Internal helper
// ---------------------------------------------------------------------------

class _Keywords {
  final List<String> primary;
  final List<String> secondary;
  const _Keywords({required this.primary, required this.secondary});
}

// ---------------------------------------------------------------------------
// Riverpod provider
// ---------------------------------------------------------------------------

final storyControllerProvider =
    StateNotifierProvider<StoryController, StoryState>(
  (ref) => StoryController(ref),
);
