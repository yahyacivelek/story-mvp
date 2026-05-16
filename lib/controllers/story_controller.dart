import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/story_models.dart';
import '../services/speech_service.dart';
import '../utils/fuzzy_matcher.dart';
import 'audio_controller.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class StoryState {
  final StoryData? storyData;
  final int activeSceneIndex;
  final bool isLoading;
  final String? error;
  final bool isListening;
  final String lastHeardText;

  const StoryState({
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
    StoryData? storyData,
    int? activeSceneIndex,
    bool? isLoading,
    String? error,
    bool? isListening,
    String? lastHeardText,
  }) {
    return StoryState(
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

  /// Rolling transcript window — keeps last ~60 words for matching.
  final List<String> _transcriptBuffer = [];
  static const int _bufferWordLimit = 60;

  /// Cooldown per audio opportunity: stores last trigger time by id.
  final Map<String, DateTime> _lastTriggered = {};

  Future<void> _init() async {
    try {
      final jsonString = await rootBundle.loadString('assets/story.json');
      final data = StoryData.fromJsonString(jsonString);

      state = state.copyWith(
        storyData: data,
        isLoading: false,
        activeSceneIndex: 0,
      );

      if (data.sceneGraph.isNotEmpty) {
        _ref
            .read(audioControllerProvider.notifier)
            .loadAndPlayAmbience(data.sceneGraph.first);
      }

      // Start listening in the story's language.
      await startListening(languageCode: data.book.language);
      debugPrint('[StoryController] STT language: ${data.book.language}');
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
    final ok = await _speech.startListening(languageCode: languageCode);
    if (!ok) return;

    state = state.copyWith(isListening: true);

    _speechSub = _speech.wordStream.listen(_onWords);
    debugPrint('[StoryController] speech listening started');
  }

  Future<void> stopListening() async {
    await _speech.stopListening();
    await _speechSub?.cancel();
    _speechSub = null;
    state = state.copyWith(isListening: false);
  }

  // -------------------------------------------------------------------------
  // Core matching logic
  // -------------------------------------------------------------------------

  void _onWords(String chunk) {
    // Accumulate into rolling buffer.
    _transcriptBuffer.addAll(chunk.split(' ').where((w) => w.isNotEmpty));
    if (_transcriptBuffer.length > _bufferWordLimit) {
      _transcriptBuffer.removeRange(
          0, _transcriptBuffer.length - _bufferWordLimit);
    }

    final transcript = _transcriptBuffer.join(' ');
    state = state.copyWith(lastHeardText: chunk);

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
    final currentIndex = state.activeSceneIndex;

    // Only try the immediately next scene (narrative order).
    final nextIndex = currentIndex + 1;
    if (nextIndex >= scenes.length) return;

    final nextScene = scenes[nextIndex];
    final activation = nextScene.sceneActivation;
    final threshold = activation.activationConfidenceThreshold;

    // Build keyword lists from entry_cues — the JSON stores them as nested
    // objects; we already parsed only the flat fields so we use scene_summary
    // keywords as a fallback plus scene_id tokens.
    //
    // primary_keywords / secondary_keywords come from the activation map
    // but our model stores only the flat fields. We derive keywords from
    // scene_summary words as secondary support, and use the current page
    // texts' key phrases as primary.
    final currentScene = scenes[currentIndex];
    final exitKeywords = _exitKeywordsForScene(currentScene);

    final hit = FuzzyMatcher.matches(
      transcript: transcript,
      primaryKeywords: exitKeywords.primary,
      secondaryKeywords: exitKeywords.secondary,
      threshold: threshold,
    );

    if (hit) {
      debugPrint(
        '[StoryController] Scene transition: ${currentScene.sceneId} → ${nextScene.sceneId}',
      );
      _transitionToScene(nextIndex);
    }
  }

  /// Extracts likely exit keywords from a scene's pages text.
  ///
  /// Since the JSON `scene_activation.exit_cues` contains keyword arrays
  /// that the model doesn't deeply parse, we derive them from the last page
  /// of the scene and the scene_summary.
  _Keywords _exitKeywordsForScene(Scene scene) {
    final data = state.storyData!;
    final pageNums = scene.pages.toSet();
    final pages = data.pages
        .where((p) => pageNums.contains(p.pageNumber))
        .toList()
      ..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));

    // Last page text words (>4 chars) as secondary.
    final lastPageWords = pages.isNotEmpty
        ? pages.last.fullText
            .toLowerCase()
            .split(RegExp(r'\s+'))
            .where((w) => w.length > 4)
            .take(8)
            .toList()
        : <String>[];

    // Scene summary words as primary.
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
    state = state.copyWith(activeSceneIndex: index);
    // Clear transcript buffer on scene change to avoid re-triggering.
    _transcriptBuffer.clear();
    _lastTriggered.clear();

    _ref
        .read(audioControllerProvider.notifier)
        .loadAndPlayAmbience(data.sceneGraph[index]);
  }

  // -------------------------------------------------------------------------

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
