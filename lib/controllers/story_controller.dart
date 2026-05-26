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
import '../services/vosk_speech_service_interface.dart';
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
  /// Map of pageNumber → character offset up to which text has been read aloud.
  final Map<int, int> readProgressOffsets;

  const StoryState({
    this.manifest,
    this.currentStoryEntry,
    this.storyData,
    this.activeSceneIndex = 0,
    this.isLoading = true,
    this.error,
    this.isListening = false,
    this.lastHeardText = '',
    this.readProgressOffsets = const {},
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
    Map<int, int>? readProgressOffsets,
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
      readProgressOffsets: readProgressOffsets ?? this.readProgressOffsets,
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
  /// Set to [true] to use Vosk offline STT instead of [SpeechService].
  /// Toggle via the [storyControllerProvider] by reading [useVosk].
  static const bool useVosk = false;

  late final _SpeechBackend _speech = useVosk
      ? _VoskBackend(VoskSpeechService.instance)
      : _SttBackend(SpeechService.instance);
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
    debugPrint('[StoryController] speech listening started (vosk=$useVosk)');
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

    // 0. Update karaoke read-progress highlights.
    _updateReadProgress();

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

    // Evaluate exit and entry cues separately (OR). Each scene's
    // activation_confidence_threshold from the JSON is used as the threshold.
    final exitThreshold =
        currentScene.sceneActivation.activationConfidenceThreshold;
    final entryThreshold =
        nextScene.sceneActivation.activationConfidenceThreshold;

    final exitScore = _cueKeywordsNonEmpty(exitKeywords)
        ? FuzzyMatcher.score(
            transcript: transcript,
            primaryKeywords: exitKeywords.primary,
            secondaryKeywords: exitKeywords.secondary,
          )
        : 0.0;
    final exitHit = exitScore >= exitThreshold;

    final entryScore = _cueKeywordsNonEmpty(entryKeywords)
        ? FuzzyMatcher.score(
            transcript: transcript,
            primaryKeywords: entryKeywords.primary,
            secondaryKeywords: entryKeywords.secondary,
          )
        : 0.0;
    final entryHit = entryScore >= entryThreshold;

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

  // -------------------------------------------------------------------------
  // Karaoke read-progress alignment
  // -------------------------------------------------------------------------

  /// Normalises [text] to a list of lowercase words with punctuation stripped,
  /// alongside the original character offset of each word's start.
  static List<({String word, int offset})> _tokenise(String text) {
    final result = <({String word, int offset})>[];
    final re = RegExp(r'[\w\u00C0-\u024F]+', unicode: true);
    for (final m in re.allMatches(text)) {
      result.add((word: m.group(0)!.toLowerCase(), offset: m.start));
    }
    return result;
  }

  /// Advances the per-page read offsets based on the current transcript buffer.
  ///
  /// Strategy: take the last up-to-10 words from [_transcriptBuffer] and
  /// slide them over the page token list looking for the best-matching window
  /// (≥ 60 % of probe words hit). When found, advance the stored offset to
  /// just past the last matched token. The offset never goes backwards.
  void _updateReadProgress() {
    final scene = state.activeScene;
    if (scene == null) return;
    final data = state.storyData;
    if (data == null) return;
    if (_transcriptBuffer.isEmpty) return;

    final pageNums = scene.pages.toSet();
    final pages = data.pages
        .where((p) => pageNums.contains(p.pageNumber))
        .toList()
      ..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));

    // Probe: last up-to-10 words from the rolling buffer.
    const probeSize = 10;
    final probe = _transcriptBuffer.length > probeSize
        ? _transcriptBuffer.sublist(_transcriptBuffer.length - probeSize)
        : List<String>.from(_transcriptBuffer);

    final updatedOffsets = Map<int, int>.from(state.readProgressOffsets);

    for (final page in pages) {
      final tokens = _tokenise(page.fullText);
      if (tokens.isEmpty) continue;

      final currentOffset = updatedOffsets[page.pageNumber] ?? 0;

      // Only search from a little before the current offset (allow slight
      // rewind in case STT re-emits an earlier partial).
      final startTokenIdx = () {
        // Find the first token whose offset >= currentOffset - 50 chars.
        final searchFrom = (currentOffset - 50).clamp(0, page.fullText.length);
        for (int i = 0; i < tokens.length; i++) {
          if (tokens[i].offset >= searchFrom) return i;
        }
        return tokens.length;
      }();

      // Slide the probe window over tokens starting from startTokenIdx.
      int bestEndOffset = currentOffset;

      for (int ti = startTokenIdx; ti <= tokens.length - probe.length; ti++) {
        int hits = 0;
        int lastHitCharEnd = currentOffset;
        for (int pi = 0; pi < probe.length; pi++) {
          if (tokens[ti + pi].word == probe[pi]) {
            hits++;
            // Character end = start of next token or end of text.
            final nextIdx = ti + pi + 1;
            lastHitCharEnd = nextIdx < tokens.length
                ? tokens[nextIdx].offset
                : page.fullText.length;
          }
        }
        final hitRate = hits / probe.length;
        if (hitRate >= 0.6 && lastHitCharEnd > bestEndOffset) {
          bestEndOffset = lastHitCharEnd;
        }
      }

      if (bestEndOffset > currentOffset) {
        updatedOffsets[page.pageNumber] = bestEndOffset;
      }
    }

    state = state.copyWith(readProgressOffsets: updatedOffsets);
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

    state = state.copyWith(activeSceneIndex: index, readProgressOffsets: {});
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
    _speech.dispose();
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
// Speech backend abstraction — allows swapping STT implementations
// ---------------------------------------------------------------------------

abstract class _SpeechBackend {
  Stream<String> get wordStream;
  Future<bool> startListening({String languageCode});
  Future<void> stopListening();
  void dispose();
}

class _SttBackend implements _SpeechBackend {
  _SttBackend(this._svc);
  final SpeechService _svc;

  @override
  Stream<String> get wordStream => _svc.wordStream;

  @override
  Future<bool> startListening({String languageCode = 'en'}) =>
      _svc.startListening(languageCode: languageCode);

  @override
  Future<void> stopListening() => _svc.stopListening();

  @override
  void dispose() => _svc.dispose();
}

class _VoskBackend implements _SpeechBackend {
  _VoskBackend(this._svc);
  final VoskSpeechService _svc;

  @override
  Stream<String> get wordStream => _svc.wordStream;

  @override
  Future<bool> startListening({String languageCode = 'en'}) =>
      _svc.startListening(languageCode: languageCode);

  @override
  Future<void> stopListening() => _svc.stopListening();

  @override
  void dispose() => _svc.dispose();
}

// ---------------------------------------------------------------------------
// Riverpod provider
// ---------------------------------------------------------------------------

final storyControllerProvider =
    StateNotifierProvider<StoryController, StoryState>(
  (ref) => StoryController(ref),
);
