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
        await _ambiencePlayer.setVolume(0.08);
        debugPrint('[AudioController] Ducked ambience for interruption');
      } else {
        // Focus returned — restore volume.
        if (state.ambienceStatus == AmbienceStatus.playing) {
          final intensity = _currentIntensity;
          await _ambiencePlayer.setVolume(_intensityToVolume(intensity));
          debugPrint('[AudioController] Audio focus restored, volume reset');
        }
      }
    });

    debugPrint('[AudioController] AudioSession configured');
  }

  String _currentIntensity = 'medium';

  /// Dedicated player for infinitely-looping background ambience.
  /// handleAudioSessionActivation=false: we manage AudioFocus ourselves via
  /// audio_session so just_audio does NOT pause on AudioFocus loss.
  final AudioPlayer _ambiencePlayer = AudioPlayer(
    handleAudioSessionActivation: false,
  );

  /// Dedicated player for foreground one-shot SFX.
  final AudioPlayer _sfxPlayer = AudioPlayer(
    handleAudioSessionActivation: false,
  );

  /// Dedicated player for looping background music layer.
  final AudioPlayer _musicPlayer = AudioPlayer(
    handleAudioSessionActivation: false,
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
      await _ambiencePlayer.setVolume(0);
      await _ambiencePlayer.stop();

      // Start new ambience.
      await _playAmbienceFromBytes(result.bytes, profile.intensity);

      // Fade in from silence over the other half.
      final targetVolume = _intensityToVolume(profile.intensity);
      final fadeInSteps = 20;
      final stepMs = (fadeOutMs / fadeInSteps).round();
      for (var i = 1; i <= fadeInSteps; i++) {
        await Future.delayed(Duration(milliseconds: stepMs));
        await _ambiencePlayer.setVolume(targetVolume * (i / fadeInSteps));
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
    String intensity,
  ) async {
    await _ambiencePlayer.stop();

    final volume = _intensityToVolume(intensity);
    debugPrint('[AudioController] Setting ambience volume: $volume (intensity: $intensity)');

    _currentIntensity = intensity;
    final byteSource = _BytesAudioSource(bytes);
    await _ambiencePlayer.setLoopMode(LoopMode.one);
    await _ambiencePlayer.setAudioSource(byteSource);
    await _ambiencePlayer.setVolume(volume);
    await _ambiencePlayer.play();
    debugPrint('[AudioController] _ambiencePlayer.play() called');
  }

  /// Pauses the ambience without disposing the player.
  Future<void> pauseAmbience() async {
    await _ambiencePlayer.pause();
    state = state.copyWith(ambienceStatus: AmbienceStatus.idle);
  }

  /// Resumes paused ambience.
  Future<void> resumeAmbience() async {
    await _ambiencePlayer.play();
    state = state.copyWith(ambienceStatus: AmbienceStatus.playing);
  }

  /// Enables or disables background ambience.
  Future<void> setAmbienceEnabled(bool enabled) async {
    state = state.copyWith(ambienceEnabled: enabled);
    if (!enabled) {
      await _ambiencePlayer.pause();
      state = state.copyWith(ambienceStatus: AmbienceStatus.idle);
    } else {
      if (_ambiencePlayer.audioSource != null) {
        await _ambiencePlayer.play();
        state = state.copyWith(ambienceStatus: AmbienceStatus.playing);
      }
    }
  }

  /// Enables or disables the music layer.
  Future<void> setMusicEnabled(bool enabled) async {
    state = state.copyWith(musicEnabled: enabled);
    if (!enabled) {
      await _musicPlayer.pause();
      state = state.copyWith(musicStatus: MusicStatus.idle);
    } else {
      if (_musicPlayer.audioSource != null) {
        await _musicPlayer.play();
        state = state.copyWith(musicStatus: MusicStatus.playing);
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
    await _musicPlayer.stop();

    final volume = _intensityToVolume(intensity) * 0.6; // Music sits below ambience
    debugPrint('[AudioController] Setting music volume: $volume (intensity: $intensity)');

    final byteSource = _BytesAudioSource(bytes);
    await _musicPlayer.setLoopMode(LoopMode.one);
    await _musicPlayer.setAudioSource(byteSource);
    await _musicPlayer.setVolume(volume);
    await _musicPlayer.play();
    debugPrint('[AudioController] _musicPlayer.play() called');
  }

  /// Stops the music layer.
  Future<void> stopMusic() async {
    await _musicPlayer.stop();
    state = state.copyWith(musicStatus: MusicStatus.idle, musicTheme: null);
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
    _ambiencePlayer.dispose();
    _sfxPlayer.dispose();
    _musicPlayer.dispose();
    super.dispose();
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
