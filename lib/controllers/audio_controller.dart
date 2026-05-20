import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../models/story_models.dart';
import '../services/elevenlabs_service.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

enum AmbienceStatus { idle, loading, playing, error }

enum MusicStatus { idle, loading, playing, error }

class AudioState {
  final AmbienceStatus ambienceStatus;
  final String? ambiencePrompt;
  final String? ambienceError;
  final MusicStatus musicStatus;
  final String? musicTheme;
  final String? musicError;
  final bool ambienceEnabled;
  final bool musicEnabled;

  /// False on web until the user taps (browser autoplay policy).
  final bool playbackUnlocked;

  /// Keys are [AudioOpportunity.eventSummary]; value is `true` while loading.
  final Map<String, bool> sfxLoadingStates;

  const AudioState({
    this.ambienceStatus = AmbienceStatus.idle,
    this.ambiencePrompt,
    this.ambienceError,
    this.musicStatus = MusicStatus.idle,
    this.musicTheme,
    this.musicError,
    this.ambienceEnabled = true,
    this.musicEnabled = true,
    this.playbackUnlocked = true,
    this.sfxLoadingStates = const {},
  });

  AudioState copyWith({
    AmbienceStatus? ambienceStatus,
    String? ambiencePrompt,
    String? ambienceError,
    MusicStatus? musicStatus,
    String? musicTheme,
    String? musicError,
    bool? ambienceEnabled,
    bool? musicEnabled,
    bool? playbackUnlocked,
    Map<String, bool>? sfxLoadingStates,
  }) {
    return AudioState(
      ambienceStatus: ambienceStatus ?? this.ambienceStatus,
      ambiencePrompt: ambiencePrompt ?? this.ambiencePrompt,
      ambienceError: ambienceError ?? this.ambienceError,
      musicStatus: musicStatus ?? this.musicStatus,
      musicTheme: musicTheme ?? this.musicTheme,
      musicError: musicError ?? this.musicError,
      ambienceEnabled: ambienceEnabled ?? this.ambienceEnabled,
      musicEnabled: musicEnabled ?? this.musicEnabled,
      playbackUnlocked: playbackUnlocked ?? this.playbackUnlocked,
      sfxLoadingStates: sfxLoadingStates ?? this.sfxLoadingStates,
    );
  }

  bool isSfxLoading(String eventSummary) =>
      sfxLoadingStates[eventSummary] ?? false;
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

class AudioController extends StateNotifier<AudioState> {
  AudioController()
      : super(AudioState(playbackUnlocked: !kIsWeb)) {
    _playbackUnlocked = !kIsWeb;
    _initAudioSession();
  }

  /// Browsers block [play] until a user gesture; toggles / taps set this.
  bool _playbackUnlocked = !kIsWeb;

  static bool _isAutoplayBlocked(Object e) {
    final msg = e.toString();
    return msg.contains('NotAllowedError') ||
        msg.contains("didn't interact");
  }

  /// Call from a user gesture (tap on story UI or audio pill).
  Future<void> unlockPlayback({Scene? scene}) async {
    if (_playbackUnlocked) return;
    _playbackUnlocked = true;
    state = state.copyWith(
      playbackUnlocked: true,
      ambienceError: null,
      musicError: null,
    );
    debugPrint('[AudioController] Playback unlocked (user gesture)');
    if (scene != null) await startSceneAudio(scene);
  }

  /// Starts ambience + music for [scene] when enabled.
  Future<void> startSceneAudio(Scene scene) async {
    if (kIsWeb && !_playbackUnlocked) return;
    await Future.wait([
      if (state.ambienceEnabled) loadAndPlayAmbience(scene),
      if (state.musicEnabled) loadAndPlayMusic(scene),
    ]);
  }

  /// Configures Android AudioFocus and handles interruptions.
  Future<void> _initAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.mixWithOthers,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
        flags: AndroidAudioFlags.none,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      androidWillPauseWhenDucked: false,
    ));

    // Listen for focus changes (e.g. STT taking transient focus).
    session.interruptionEventStream.listen((event) async {
      debugPrint('[AudioController] interruption: begin=${event.begin} type=${event.type}');
      if (event.begin) {
        // Duck on all transient interruptions (STT, notifications).
        // Never pause — we hold permanent GAIN focus so this is just courtesy.
        await _ambienceLooper.setVolume(0.08);
        debugPrint('[AudioController] Ducked ambience for interruption');
      } else {
        // Focus returned — restore volume.
        if (state.ambienceStatus == AmbienceStatus.playing) {
          final intensity = _currentIntensity;
          await _ambienceLooper.setVolume(_intensityToVolume(intensity));
          debugPrint('[AudioController] Audio focus restored, volume reset');
        }
      }
    });

    debugPrint('[AudioController] AudioSession configured');
  }

  String _currentIntensity = 'medium';
  String? _currentMusicIntensity;
  int _fadeToken = 0;

  /// Seamless looper for background ambience — crossfades between two
  /// players to eliminate the click/pop at loop boundaries.
  final _SeamlessLooper _ambienceLooper = _SeamlessLooper(
    crossfadeDuration: const Duration(seconds: 2),
    label: 'AmbienceLooper',
  );

  /// Dedicated player for foreground one-shot SFX.
  final AudioPlayer _sfxPlayer = AudioPlayer(
    handleAudioSessionActivation: false,
  );

  /// Seamless looper for background music — crossfades between two
  /// players to eliminate the click/pop at loop boundaries.
  final _SeamlessLooper _musicLooper = _SeamlessLooper(
    crossfadeDuration: const Duration(seconds: 3),
    label: 'MusicLooper',
  );

  final ElevenLabsService _api = ElevenLabsService.instance;

  // -------------------------------------------------------------------------
  // Volume helpers
  // -------------------------------------------------------------------------

  static double _intensityToVolume(String intensity) => switch (intensity) {
        'low' => 0.20,
        'medium' => 0.35,
        'high' => 0.50,
        _ => 0.35,
      };

  static double _mixLevelToVolume(String mixLevel) => switch (mixLevel) {
        'subtle' => 0.40,
        'medium' => 0.70,
        'prominent' => 1.00,
        _ => 0.70,
      };

  // -------------------------------------------------------------------------
  // Ambience
  // -------------------------------------------------------------------------

  // -----------------------------------------------------------------------
  // Scene transition with crossfade
  // -----------------------------------------------------------------------

  /// Transitions audio to [scene] respecting [SceneTransition] metadata.
  ///
  /// - `audio_continuity: evolve` — fade out old ambience while fading in new.
  /// - `audio_continuity: continue` — keep current ambience, only update music.
  /// - `audio_continuity: replace` — stop old audio, start new after brief gap.
  Future<void> transitionToScene(
    Scene scene, {
    SceneTransition? transition,
  }) async {
    final continuity = transition?.audioContinuity ?? 'evolve';
    final durationSeconds =
        transition?.transitionDurationSeconds ?? 2;

    switch (continuity) {
      case 'continue':
        // Keep ambience bed, update music — recover stalled loopers + volume.
        await loadAndPlayMusic(scene);
        await _ensureAmbiencePlaying(scene);
        await _ensureMusicPlaying(scene);
        break;

      case 'replace':
        // Hard cut: stop old audio, then start new.
        await pauseAmbience();
        await stopMusic();
        await Future.delayed(Duration(milliseconds: (durationSeconds * 500).round()));
        await Future.wait([
          loadAndPlayAmbience(scene),
          loadAndPlayMusic(scene),
        ]);
        break;

      case 'evolve':
      default:
        if (kIsWeb) {
          // Web: skip volume-0 crossfade (often inaudible / leaves volume at 0).
          await Future.wait([
            loadAndPlayAmbience(scene),
            loadAndPlayMusic(scene),
          ]);
        } else {
          // Fetch + start music while ambience crossfades — avoids waiting
          // for the full fade-in before music begins.
          await Future.wait([
            _crossfadeAmbience(scene, durationSeconds),
            loadAndPlayMusic(scene),
          ]);
        }
        break;
    }
  }

  /// Crossfades from current ambience to [scene]'s ambience over
  /// [durationSeconds].
  Future<void> _crossfadeAmbience(Scene scene, int durationSeconds) async {
    if (!state.ambienceEnabled) return;
    if (kIsWeb && !_playbackUnlocked) return;
    final profile = scene.sceneAudio.primaryAmbience.soundProfile;
    final secondary = scene.sceneAudio.secondaryLayers.isNotEmpty
        ? scene.sceneAudio.secondaryLayers.first
        : null;
    final prompt = profile.buildAmbiencePrompt(secondary: secondary);

    // Guard: don't re-fetch if already playing this exact prompt.
    if (state.ambiencePrompt == prompt &&
        state.ambienceStatus == AmbienceStatus.playing) {
      return;
    }

    state = state.copyWith(
      ambienceStatus: AmbienceStatus.loading,
      ambiencePrompt: prompt,
      ambienceError: null,
    );

    try {
      final result = await _api.fetchAmbience(prompt);

      if (result.isMissing) {
        debugPrint('[AudioController] Crossfade SKIP: ambience not cached (offline mode)');
        state = state.copyWith(
          ambienceStatus: AmbienceStatus.error,
          ambienceError: 'Audio not cached – run with offlineMode=false once to generate',
        );
        return;
      }

      // Fade out current ambience over half the transition duration.
      final fadeOutMs = (durationSeconds * 500).round();
      await _ambienceLooper.setVolume(0);
      await _ambienceLooper.stop();

      // Start new ambience at silence.
      await _playAmbienceFromBytes(result.bytes!, profile.intensity, initialVolume: 0);

      state = state.copyWith(ambienceStatus: AmbienceStatus.playing);
      debugPrint('[AudioController] Crossfade ambience started, fading in');

      await _fadeInAmbience(_intensityToVolume(profile.intensity), fadeOutMs);
    } catch (e, st) {
      debugPrint('[AudioController] Crossfade ERROR: $e\n$st');
      if (_isAutoplayBlocked(e)) {
        _playbackUnlocked = false;
        state = state.copyWith(
          playbackUnlocked: false,
          ambienceStatus: AmbienceStatus.idle,
          ambienceError: 'Tap the story to enable audio',
        );
      } else {
        state = state.copyWith(
          ambienceStatus: AmbienceStatus.error,
          ambienceError: e.toString(),
        );
      }
    }
  }

  /// Stops any current ambience and starts a new one for [scene].
  Future<void> loadAndPlayAmbience(Scene scene) async {
    if (!state.ambienceEnabled) return;
    if (kIsWeb && !_playbackUnlocked) return;
    final profile = scene.sceneAudio.primaryAmbience.soundProfile;
    final secondary = scene.sceneAudio.secondaryLayers.isNotEmpty
        ? scene.sceneAudio.secondaryLayers.first
        : null;

    final prompt = profile.buildAmbiencePrompt(secondary: secondary);

    // Guard: don't re-fetch if already playing this exact prompt.
    if (state.ambiencePrompt == prompt &&
        state.ambienceStatus == AmbienceStatus.playing) {
      return;
    }

    state = state.copyWith(
      ambienceStatus: AmbienceStatus.loading,
      ambiencePrompt: prompt,
      ambienceError: null,
    );

    debugPrint('[AudioController] Fetching ambience: "$prompt"');

    try {
      final result = await _api.fetchAmbience(prompt);

      if (result.isMissing) {
        debugPrint('[AudioController] Ambience SKIP: not cached (offline mode)');
        state = state.copyWith(
          ambienceStatus: AmbienceStatus.error,
          ambienceError: 'Audio not cached – run with offlineMode=false once to generate',
        );
        return;
      }

      debugPrint(
        '[AudioController] Ambience fetched: ${result.bytes!.length} bytes '
        '(fromCache: ${result.fromCache})',
      );
      await _playAmbienceFromBytes(result.bytes!, profile.intensity);
      state = state.copyWith(ambienceStatus: AmbienceStatus.playing);
      debugPrint('[AudioController] Ambience playing');
    } catch (e, st) {
      debugPrint('[AudioController] Ambience ERROR: $e\n$st');
      if (_isAutoplayBlocked(e)) {
        _playbackUnlocked = false;
        state = state.copyWith(
          playbackUnlocked: false,
          ambienceStatus: AmbienceStatus.idle,
          ambienceError: 'Tap the story to enable audio',
        );
      } else {
        state = state.copyWith(
          ambienceStatus: AmbienceStatus.error,
          ambienceError: e.toString(),
        );
      }
    }
  }

  Future<void> _playAmbienceFromBytes(
    Uint8List bytes,
    String intensity, {
    double? initialVolume,
  }) async {
    // Note: _ambienceLooper.play() already stops both internal players,
    // so no need to call stop() here — avoids redundant platform-channel round-trips.

    final volume = _intensityToVolume(intensity);
    debugPrint('[AudioController] Setting ambience volume: $volume (intensity: $intensity)');

    _currentIntensity = intensity;
    await _ambienceLooper.play(bytes, volume, initialVolume: initialVolume);
    debugPrint('[AudioController] _ambienceLooper.play() called');
  }

  /// Gradually fades ambience in to [targetVolume] over [durationMs].
  /// Non-blocking — returns immediately. Uses [_fadeToken] for cancellation:
  /// if a new transition starts, incrementing the token cancels this fade.
  Future<void> _fadeInAmbience(double targetVolume, int durationMs) async {
    final token = ++_fadeToken;
    final fadeInSteps = 20;
    final stepMs = (durationMs / fadeInSteps).round().clamp(1, 500);
    try {
      for (var i = 1; i <= fadeInSteps; i++) {
        if (_fadeToken != token) return;
        await Future.delayed(Duration(milliseconds: stepMs));
        if (_fadeToken != token) return;
        await _ambienceLooper.setVolume(targetVolume * (i / fadeInSteps));
      }
    } finally {
      // If a newer transition cancelled the fade, don't leave volume at 0.
      if (_fadeToken == token) {
        await _ambienceLooper.setVolume(targetVolume);
      }
    }
  }

  /// Pauses the ambience without disposing the player.
  Future<void> pauseAmbience() async {
    await _ambienceLooper.pause();
    state = state.copyWith(ambienceStatus: AmbienceStatus.idle);
  }

  /// Fully stops ambience, clears the audio source and resets state.
  Future<void> stopAmbience() async {
    await _ambienceLooper.stop();
    state = state.copyWith(
      ambienceStatus: AmbienceStatus.idle,
      ambiencePrompt: null,
      ambienceError: null,
    );
  }

  /// Resumes paused ambience.
  Future<void> resumeAmbience() async {
    await _ambienceLooper.resume();
    state = state.copyWith(ambienceStatus: AmbienceStatus.playing);
  }

  /// Enables or disables background ambience.
  ///
  /// Pass [scene] when re-enabling so ambience can be reloaded if the looper
  /// has no source (e.g. after a failed crossfade).
  Future<void> setAmbienceEnabled(bool enabled, {Scene? scene}) async {
    if (enabled) await unlockPlayback(scene: scene);
    state = state.copyWith(ambienceEnabled: enabled);
    if (!enabled) {
      await _ambienceLooper.pause();
      state = state.copyWith(ambienceStatus: AmbienceStatus.idle);
    } else {
      if (_ambienceLooper.hasSource) {
        await _ambienceLooper.setVolume(_intensityToVolume(_currentIntensity));
        await _ambienceLooper.resume();
        state = state.copyWith(ambienceStatus: AmbienceStatus.playing);
      } else if (scene != null) {
        await loadAndPlayAmbience(scene);
      }
    }
  }

  /// Keeps ambience running on `continue` transitions, or restarts it if the
  /// seamless looper stalled (e.g. after a failed loop crossfade).
  Future<void> _ensureAmbiencePlaying(Scene scene) async {
    if (!state.ambienceEnabled) return;
    if (kIsWeb && !_playbackUnlocked) return;
    if (!_ambienceLooper.hasSource ||
        state.ambienceStatus != AmbienceStatus.playing) {
      await loadAndPlayAmbience(scene);
    } else {
      await _ambienceLooper.setVolume(_intensityToVolume(_currentIntensity));
      await _ambienceLooper.resume();
    }
  }

  /// Same as [_ensureAmbiencePlaying] but for the music looper.
  Future<void> _ensureMusicPlaying(Scene scene) async {
    if (!state.musicEnabled) return;
    if (kIsWeb && !_playbackUnlocked) return;
    final musicLayer = scene.sceneAudio.musicLayer;
    if (musicLayer == null || !musicLayer.enabled) return;

    if (!_musicLooper.hasSource ||
        state.musicStatus != MusicStatus.playing) {
      await loadAndPlayMusic(scene);
    } else {
      final vol = _intensityToVolume(musicLayer.intensity) * 0.5;
      await _musicLooper.setVolume(vol);
      await _musicLooper.resume();
    }
  }

  // -------------------------------------------------------------------------
  // Music layer
  // -------------------------------------------------------------------------

  /// Loads and plays the music layer for [scene] if enabled.
  Future<void> loadAndPlayMusic(Scene scene) async {
    if (!state.musicEnabled) return;
    if (kIsWeb && !_playbackUnlocked) return;
    final musicLayer = scene.sceneAudio.musicLayer;
    if (musicLayer == null || !musicLayer.enabled) {
      await stopMusic();
      return;
    }

    final theme = musicLayer.musicTheme;

    // Guard: don't re-fetch if already playing this theme.
    if (state.musicTheme == theme && state.musicStatus == MusicStatus.playing) {
      return;
    }

    state = state.copyWith(
      musicStatus: MusicStatus.loading,
      musicTheme: theme,
      musicError: null,
    );

    debugPrint('[AudioController] Fetching music: theme="$theme"');

    try {
      final result = await _api.fetchMusic(theme);

      if (result.isMissing) {
        debugPrint('[AudioController] Music SKIP: not cached (offline mode)');
        state = state.copyWith(
          musicStatus: MusicStatus.error,
          musicError: 'Audio not cached – run with offlineMode=false once to generate',
        );
        return;
      }

      debugPrint(
        '[AudioController] Music fetched: ${result.bytes!.length} bytes '
        '(fromCache: ${result.fromCache})',
      );
      await _playMusicFromBytes(result.bytes!, musicLayer.intensity);
      state = state.copyWith(musicStatus: MusicStatus.playing);
      debugPrint('[AudioController] Music playing');
    } catch (e, st) {
      debugPrint('[AudioController] Music ERROR: $e\n$st');
      if (_isAutoplayBlocked(e)) {
        _playbackUnlocked = false;
        state = state.copyWith(
          playbackUnlocked: false,
          musicStatus: MusicStatus.idle,
          musicError: 'Tap the story to enable audio',
        );
      } else {
        state = state.copyWith(
          musicStatus: MusicStatus.error,
          musicError: e.toString(),
        );
      }
    }
  }

  Future<void> _playMusicFromBytes(Uint8List bytes, String intensity) async {
    // Note: _musicLooper.play() already stops both internal players,
    // so no need to call stop() here — avoids redundant platform-channel round-trips.

    _currentMusicIntensity = intensity;
    final volume = _intensityToVolume(intensity) * 0.5; // Music sits well below ambience
    debugPrint('[AudioController] Setting music volume: $volume (intensity: $intensity)');

    await _musicLooper.play(bytes, volume);
    debugPrint('[AudioController] _musicLooper.play() called');
  }

  /// Stops the music layer.
  Future<void> stopMusic() async {
    await _musicLooper.stop();
    state = state.copyWith(musicStatus: MusicStatus.idle, musicTheme: null);
  }

  /// Enables or disables the music layer.
  Future<void> setMusicEnabled(bool enabled, {Scene? scene}) async {
    if (enabled) await unlockPlayback(scene: scene);
    state = state.copyWith(musicEnabled: enabled);
    if (!enabled) {
      await _musicLooper.pause();
      state = state.copyWith(musicStatus: MusicStatus.idle);
    } else {
      if (_musicLooper.hasSource) {
        final vol = _currentMusicIntensity != null
            ? _intensityToVolume(_currentMusicIntensity!) * 0.5
            : 0.25;
        await _musicLooper.setVolume(vol);
        await _musicLooper.resume();
        state = state.copyWith(musicStatus: MusicStatus.playing);
      } else if (scene != null) {
        await loadAndPlayMusic(scene);
      }
    }
  }

  // -------------------------------------------------------------------------
  // SFX
  // -------------------------------------------------------------------------

  /// Fetches and plays a sound effect for [opportunity].
  ///
  /// Ducks ambience and music while the SFX plays so the effect is
  /// clearly audible, then restores them afterwards.
  Future<void> playSfx(AudioOpportunity opportunity) async {
    final prompt = opportunity.eventSummary;

    // Prevent double-tap while already loading.
    if (state.isSfxLoading(prompt)) return;

    // Mark as loading.
    state = state.copyWith(
      sfxLoadingStates: {...state.sfxLoadingStates, prompt: true},
    );

    try {
      final result = await _api.fetchSfx(prompt);
      if (result.isMissing) {
        debugPrint('[AudioController] SFX SKIP: not cached (offline mode) – $prompt');
        return;
      }
      await _duckAndPlaySfx(result.bytes!, opportunity.mixLevel);
    } finally {
      // Clear loading flag whether success or error.
      final updated = Map<String, bool>.from(state.sfxLoadingStates)
        ..remove(prompt);
      state = state.copyWith(sfxLoadingStates: updated);
    }
  }

  // -----------------------------------------------------------------------
  // SFX ducking — lowers ambience/music while an effect plays
  // -----------------------------------------------------------------------

  /// Volume the background layers are ducked to while an SFX plays.
  static const double _duckVolume = 0.05;

  /// Duration to fade background back in after an SFX finishes.
  static const Duration _unduckFadeDuration = Duration(seconds: 2);

  /// Steps used for the fade-in restore.
  static const int _unduckSteps = 20;

  StreamSubscription<ProcessingState>? _sfxCompletionSub;

  /// Ducks ambience & music, plays the SFX, then restores backgrounds.
  Future<void> _duckAndPlaySfx(Uint8List bytes, String mixLevel) async {
    // Cancel any pending restore from a previous SFX.
    await _sfxCompletionSub?.cancel();
    _sfxCompletionSub = null;

    // 1. Duck ambience and music immediately.
    await _ambienceLooper.setVolume(_duckVolume);
    await _musicLooper.setVolume(_duckVolume);

    // 2. Play the SFX.
    await _sfxPlayer.stop();
    final byteSource = _BytesAudioSource(bytes);
    await _sfxPlayer.setAudioSource(byteSource);
    await _sfxPlayer.setVolume(_mixLevelToVolume(mixLevel));
    await _sfxPlayer.play();

    // 3. Listen for SFX completion to restore background volumes.
    _sfxCompletionSub = _sfxPlayer.processingStateStream
        .where((s) => s == ProcessingState.completed)
        .take(1)
        .listen((_) {
      _sfxCompletionSub?.cancel();
      _sfxCompletionSub = null;
      _unduckBackgrounds();
    });
  }

  /// Gradually restores ambience and music to their normal volumes.
  Future<void> _unduckBackgrounds() async {
    final ambienceTarget = _intensityToVolume(_currentIntensity);
    final musicTarget = _currentMusicIntensity != null
        ? _intensityToVolume(_currentMusicIntensity!) * 0.5
        : 0.25;

    final stepMs =
        _unduckFadeDuration.inMilliseconds ~/ _unduckSteps;

    for (var i = 1; i <= _unduckSteps; i++) {
      await Future.delayed(Duration(milliseconds: stepMs));
      final t = i / _unduckSteps;
      await _ambienceLooper.setVolume(
        _duckVolume + (ambienceTarget - _duckVolume) * t,
      );
      await _musicLooper.setVolume(
        _duckVolume + (musicTarget - _duckVolume) * t,
      );
    }
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void dispose() {
    _sfxCompletionSub?.cancel();
    _ambienceLooper.dispose();
    _sfxPlayer.dispose();
    _musicLooper.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Seamless looper — dual-player crossfade for click-free looping
// ---------------------------------------------------------------------------

/// Manages two [AudioPlayer] instances and crossfades between them near the
/// end of each cycle, producing seamless loops without the click/pop artefact
/// that occurs when [LoopMode.one] restarts a clip from its boundary.
///
/// Uses an equal-power crossfade curve (`cos`/`sin`) so the perceived
/// loudness stays constant throughout the transition.
class _SeamlessLooper {
  final AudioPlayer _playerA;
  final AudioPlayer _playerB;
  final Duration crossfadeDuration;
  final int _crossfadeSteps;
  final String _label;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<ProcessingState>? _processingSub;
  bool _activeIsA = true;
  bool _crossfading = false;
  bool _disposed = false;
  bool _bothPlayersLoaded = false;
  double _targetVolume = 1.0;
  Uint8List? _currentBytes;
  _BytesAudioSource? _sourceA;
  _BytesAudioSource? _sourceB;

  _SeamlessLooper({
    this.crossfadeDuration = const Duration(seconds: 2),
    int crossfadeSteps = 30,
    String label = 'SeamlessLooper',
  })  : _label = label,
        _playerA = AudioPlayer(handleAudioSessionActivation: false),
        _playerB = AudioPlayer(handleAudioSessionActivation: false),
        _crossfadeSteps = crossfadeSteps;

  AudioPlayer get _active => _activeIsA ? _playerA : _playerB;
  AudioPlayer get _standby => _activeIsA ? _playerB : _playerA;

  /// Whether a source has been loaded (i.e. [play] was called successfully).
  bool get hasSource => _currentBytes != null;

  /// Starts playback from [bytes] at [volume].
  ///
  /// Set [initialVolume] to start at a different volume (e.g. `0` for a
  /// fade-in); defaults to [volume] when omitted.
  Future<void> play(Uint8List bytes, double volume, {double? initialVolume}) async {
    _currentBytes = bytes;
    _targetVolume = volume;
    _crossfading = false;
    _positionSub?.cancel();

    await Future.wait([
      _playerA.stop(),
      _playerB.stop(),
    ]);

    // LoopMode.one is a safety net if a crossfade is delayed.
    await Future.wait([
      _playerA.setLoopMode(LoopMode.one),
      _playerB.setLoopMode(LoopMode.one),
    ]);

    // Load both players once — loop crossfades only swap play/volume, never
    // call setAudioSource again (avoids platform dispose churn / errors).
    _sourceA = _BytesAudioSource(bytes);
    _sourceB = _BytesAudioSource(bytes);
    await Future.wait([
      _playerA.setAudioSource(_sourceA!),
      _playerB.setAudioSource(_sourceB!),
    ]);
    _bothPlayersLoaded = true;

    final startVol = initialVolume ?? volume;
    await _playerB.setVolume(0);
    await _playerB.pause();
    await _playerA.setVolume(startVol);
    await _playerA.play();
    _activeIsA = true;

    _startPositionMonitoring();
  }

  void _startPositionMonitoring() {
    _positionSub?.cancel();
    _processingSub?.cancel();

    if (kIsWeb) {
      // Web: duration/position-based crossfade is unreliable — restart on end.
      _processingSub = _active.processingStateStream.listen((ps) {
        if (_disposed || _crossfading || _currentBytes == null) return;
        if (ps == ProcessingState.completed) {
          unawaited(_restartActiveFromStart());
        }
      });
      return;
    }

    _positionSub = _active.positionStream.listen(_onPositionUpdate);
  }

  Future<void> _restartActiveFromStart() async {
    try {
      await _active.seek(Duration.zero);
      await _active.play();
    } catch (e) {
      debugPrint('[$_label] Loop restart failed: $e');
    }
  }

  void _onPositionUpdate(Duration position) {
    if (_disposed || _crossfading || kIsWeb) return;
    final duration = _active.duration;
    if (duration == null || duration <= crossfadeDuration) return;

    final triggerPoint = duration - crossfadeDuration;
    if (position >= triggerPoint) {
      _crossfading = true;
      _positionSub?.cancel();
      _initiateCrossfade();
    }
  }

  Future<void> _initiateCrossfade() async {
    if (_currentBytes == null || _disposed || !_bothPlayersLoaded) {
      _crossfading = false;
      return;
    }

    final outgoing = _active;
    final incoming = _standby;

    try {
      // Standby already has the same source from [play] — no setAudioSource.
      await incoming.setVolume(0);
      await incoming.seek(Duration.zero);
      await incoming.play();

      final stepMs = crossfadeDuration.inMilliseconds ~/ _crossfadeSteps;
      for (var i = 1; i <= _crossfadeSteps; i++) {
        if (_disposed || _currentBytes == null) return;
        await Future.delayed(Duration(milliseconds: stepMs));
        final t = i / _crossfadeSteps;
        final outVol = _targetVolume * cos(pi / 2 * t);
        final inVol = _targetVolume * sin(pi / 2 * t);
        await outgoing.setVolume(outVol);
        await incoming.setVolume(inVol);
      }

      await outgoing.pause();
      await outgoing.seek(Duration.zero);
      _activeIsA = !_activeIsA;
    } catch (e, st) {
      debugPrint(
        '[$_label] Crossfade failed, restarting active player: $e\n$st',
      );
      await _recoverFromCrossfadeFailure();
    } finally {
      _crossfading = false;
      if (!_disposed && _currentBytes != null) {
        _startPositionMonitoring();
      }
    }
  }

  Future<void> _recoverFromCrossfadeFailure() async {
    try {
      await _standby.pause();
      await _standby.setVolume(0);
      await _active.setVolume(_targetVolume);
      await _active.seek(Duration.zero);
      await _active.play();
    } catch (e) {
      debugPrint('[$_label] Recovery failed: $e');
    }
  }

  /// Sets the target volume. During a crossfade the new target is picked up
  /// by subsequent crossfade steps; outside a crossfade it is applied
  /// immediately to the active player.
  Future<void> setVolume(double volume) async {
    _targetVolume = volume;
    if (!_crossfading) {
      await _active.setVolume(volume);
    }
  }

  Future<void> pause() async {
    _positionSub?.cancel();
    _processingSub?.cancel();
    _crossfading = false;
    await _playerA.pause();
    await _playerB.pause();
  }

  Future<void> resume() async {
    await _active.play();
    _startPositionMonitoring();
  }

  Future<void> stop() async {
    _positionSub?.cancel();
    _processingSub?.cancel();
    _crossfading = false;
    _bothPlayersLoaded = false;
    await _playerA.stop();
    await _playerB.stop();
    _currentBytes = null;
    _sourceA = null;
    _sourceB = null;
  }

  void dispose() {
    _disposed = true;
    _positionSub?.cancel();
    _processingSub?.cancel();
    _playerA.dispose();
    _playerB.dispose();
  }
}

// ---------------------------------------------------------------------------
// In-memory audio source adapter for just_audio
// ---------------------------------------------------------------------------

/// Adapts a raw [Uint8List] to a [StreamAudioSource] so just_audio can play
/// audio bytes without writing them to disk.
class _BytesAudioSource extends StreamAudioSource {
  final Uint8List _bytes;

  _BytesAudioSource(this._bytes);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= _bytes.length;

    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(_bytes.sublist(start, end)),
      contentType: 'audio/mpeg',
    );
  }
}

// ---------------------------------------------------------------------------
// Riverpod provider
// ---------------------------------------------------------------------------

final audioControllerProvider =
    StateNotifierProvider<AudioController, AudioState>(
  (ref) => AudioController(),
);
