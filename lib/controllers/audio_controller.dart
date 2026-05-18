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
  AudioController() : super(const AudioState()) {
    _initAudioSession();
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

  /// Seamless looper for background ambience — crossfades between two
  /// players to eliminate the click/pop at loop boundaries.
  final _SeamlessLooper _ambienceLooper = _SeamlessLooper(
    crossfadeDuration: const Duration(seconds: 2),
  );

  /// Dedicated player for foreground one-shot SFX.
  final AudioPlayer _sfxPlayer = AudioPlayer(
    handleAudioSessionActivation: false,
  );

  /// Seamless looper for background music — crossfades between two
  /// players to eliminate the click/pop at loop boundaries.
  final _SeamlessLooper _musicLooper = _SeamlessLooper(
    crossfadeDuration: const Duration(seconds: 3),
  );

  final ElevenLabsService _api = ElevenLabsService.instance;

  // -------------------------------------------------------------------------
  // Volume helpers
  // -------------------------------------------------------------------------

  static double _intensityToVolume(String intensity) => switch (intensity) {
        'low' => 0.50,
        'medium' => 0.70,
        'high' => 1.00,
        _ => 0.70,
      };

  static double _mixLevelToVolume(String mixLevel) => switch (mixLevel) {
        'subtle' => 0.30,
        'medium' => 0.60,
        'prominent' => 0.90,
        _ => 0.60,
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
        // Keep ambience, only update music.
        await loadAndPlayMusic(scene);
        break;

      case 'replace':
        // Hard cut: stop old audio, then start new.
        await pauseAmbience();
        await stopMusic();
        await Future.delayed(Duration(milliseconds: (durationSeconds * 500).round()));
        await loadAndPlayAmbience(scene);
        await loadAndPlayMusic(scene);
        break;

      case 'evolve':
      default:
        // Crossfade: fade out old ambience, fade in new.
        await _crossfadeAmbience(scene, durationSeconds);
        await loadAndPlayMusic(scene);
        break;
    }
  }

  /// Crossfades from current ambience to [scene]'s ambience over
  /// [durationSeconds].
  Future<void> _crossfadeAmbience(Scene scene, int durationSeconds) async {
    if (!state.ambienceEnabled) return;
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

      // Fade out current ambience over half the transition duration.
      final fadeOutMs = (durationSeconds * 500).round();
      await _ambienceLooper.setVolume(0);
      await _ambienceLooper.stop();

      // Start new ambience at silence, then fade in.
      await _playAmbienceFromBytes(result.bytes, profile.intensity, initialVolume: 0);

      // Fade in from silence over the other half.
      final targetVolume = _intensityToVolume(profile.intensity);
      final fadeInSteps = 20;
      final stepMs = (fadeOutMs / fadeInSteps).round();
      for (var i = 1; i <= fadeInSteps; i++) {
        await Future.delayed(Duration(milliseconds: stepMs));
        await _ambienceLooper.setVolume(targetVolume * (i / fadeInSteps));
      }

      state = state.copyWith(ambienceStatus: AmbienceStatus.playing);
      debugPrint('[AudioController] Crossfade ambience complete');
    } catch (e, st) {
      debugPrint('[AudioController] Crossfade ERROR: $e\n$st');
      state = state.copyWith(
        ambienceStatus: AmbienceStatus.error,
        ambienceError: e.toString(),
      );
    }
  }

  /// Stops any current ambience and starts a new one for [scene].
  Future<void> loadAndPlayAmbience(Scene scene) async {
    if (!state.ambienceEnabled) return;
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
      debugPrint(
        '[AudioController] Ambience fetched: ${result.bytes.length} bytes '
        '(fromCache: ${result.fromCache})',
      );
      await _playAmbienceFromBytes(result.bytes, profile.intensity);
      state = state.copyWith(ambienceStatus: AmbienceStatus.playing);
      debugPrint('[AudioController] Ambience playing');
    } catch (e, st) {
      debugPrint('[AudioController] Ambience ERROR: $e\n$st');
      state = state.copyWith(
        ambienceStatus: AmbienceStatus.error,
        ambienceError: e.toString(),
      );
    }
  }

  Future<void> _playAmbienceFromBytes(
    Uint8List bytes,
    String intensity, {
    double? initialVolume,
  }) async {
    await _ambienceLooper.stop();

    final volume = _intensityToVolume(intensity);
    debugPrint('[AudioController] Setting ambience volume: $volume (intensity: $intensity)');

    _currentIntensity = intensity;
    await _ambienceLooper.play(bytes, volume, initialVolume: initialVolume);
    debugPrint('[AudioController] _ambienceLooper.play() called');
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
  Future<void> setAmbienceEnabled(bool enabled) async {
    state = state.copyWith(ambienceEnabled: enabled);
    if (!enabled) {
      await _ambienceLooper.pause();
      state = state.copyWith(ambienceStatus: AmbienceStatus.idle);
    } else {
      if (_ambienceLooper.hasSource) {
        await _ambienceLooper.resume();
        state = state.copyWith(ambienceStatus: AmbienceStatus.playing);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Music layer
  // -------------------------------------------------------------------------

  /// Loads and plays the music layer for [scene] if enabled.
  Future<void> loadAndPlayMusic(Scene scene) async {
    if (!state.musicEnabled) return;
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
      debugPrint(
        '[AudioController] Music fetched: ${result.bytes.length} bytes '
        '(fromCache: ${result.fromCache})',
      );
      await _playMusicFromBytes(result.bytes, musicLayer.intensity);
      state = state.copyWith(musicStatus: MusicStatus.playing);
      debugPrint('[AudioController] Music playing');
    } catch (e, st) {
      debugPrint('[AudioController] Music ERROR: $e\n$st');
      state = state.copyWith(
        musicStatus: MusicStatus.error,
        musicError: e.toString(),
      );
    }
  }

  Future<void> _playMusicFromBytes(Uint8List bytes, String intensity) async {
    await _musicLooper.stop();

    final volume = _intensityToVolume(intensity) * 0.6; // Music sits below ambience
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
  Future<void> setMusicEnabled(bool enabled) async {
    state = state.copyWith(musicEnabled: enabled);
    if (!enabled) {
      await _musicLooper.pause();
      state = state.copyWith(musicStatus: MusicStatus.idle);
    } else {
      if (_musicLooper.hasSource) {
        await _musicLooper.resume();
        state = state.copyWith(musicStatus: MusicStatus.playing);
      }
    }
  }

  // -------------------------------------------------------------------------
  // SFX
  // -------------------------------------------------------------------------

  /// Fetches and plays a sound effect for [opportunity].
  ///
  /// Ambience continues uninterrupted.
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
      await _playSfxFromBytes(result.bytes, opportunity.mixLevel);
    } finally {
      // Clear loading flag whether success or error.
      final updated = Map<String, bool>.from(state.sfxLoadingStates)
        ..remove(prompt);
      state = state.copyWith(sfxLoadingStates: updated);
    }
  }

  Future<void> _playSfxFromBytes(Uint8List bytes, String mixLevel) async {
    // Stop any previously playing SFX (but not the ambience).
    await _sfxPlayer.stop();

    final byteSource = _BytesAudioSource(bytes);
    await _sfxPlayer.setAudioSource(byteSource);
    await _sfxPlayer.setVolume(_mixLevelToVolume(mixLevel));
    await _sfxPlayer.play();
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void dispose() {
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

  StreamSubscription<Duration>? _positionSub;
  bool _activeIsA = true;
  bool _crossfading = false;
  bool _disposed = false;
  double _targetVolume = 1.0;
  Uint8List? _currentBytes;

  _SeamlessLooper({
    this.crossfadeDuration = const Duration(seconds: 2),
    int crossfadeSteps = 30,
  })  : _playerA = AudioPlayer(handleAudioSessionActivation: false),
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

    await _playerA.stop();
    await _playerB.stop();

    // Set LoopMode.one as safety net — the looper crossfades before the
    // clip ends, but if a crossfade is delayed the player keeps going
    // instead of stopping dead.
    await _playerA.setLoopMode(LoopMode.one);
    await _playerB.setLoopMode(LoopMode.one);

    final startVol = initialVolume ?? volume;
    await _playerA.setAudioSource(_BytesAudioSource(bytes));
    await _playerA.setVolume(startVol);
    await _playerA.play();
    _activeIsA = true;

    _startPositionMonitoring();
  }

  void _startPositionMonitoring() {
    _positionSub?.cancel();
    _positionSub = _active.positionStream.listen(_onPositionUpdate);
  }

  void _onPositionUpdate(Duration position) {
    if (_disposed || _crossfading) return;
    final duration = _active.duration;
    if (duration == null || duration <= crossfadeDuration) return;

    final triggerPoint = duration - crossfadeDuration;
    if (position >= triggerPoint) {
      _crossfading = true; // Guard immediately to prevent re-entry.
      _positionSub?.cancel();
      _initiateCrossfade(); // Fire-and-forget; _crossfading guards.
    }
  }

  Future<void> _initiateCrossfade() async {
    if (_currentBytes == null || _disposed) return;
    // _crossfading already set to true by _onPositionUpdate.

    final outgoing = _active;
    final incoming = _standby;

    // Prepare incoming player at zero volume.
    await incoming.setAudioSource(_BytesAudioSource(_currentBytes!));
    await incoming.setVolume(0);
    await incoming.seek(Duration.zero);
    await incoming.play();

    // Equal-power crossfade: cos/sin curve keeps perceived loudness constant.
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

    // Reset outgoing player for the next cycle.
    await outgoing.pause();
    await outgoing.seek(Duration.zero);

    _activeIsA = !_activeIsA;
    _crossfading = false;

    if (!_disposed) _startPositionMonitoring();
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
    _crossfading = false;
    await _playerA.stop();
    await _playerB.stop();
    _currentBytes = null;
  }

  void dispose() {
    _disposed = true;
    _positionSub?.cancel();
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
