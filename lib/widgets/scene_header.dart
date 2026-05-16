import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/audio_controller.dart';
import '../controllers/story_controller.dart';
import '../models/story_models.dart';

/// Slim top bar: scene title on the left, compact audio status pills on the right.
/// Keeps vertical space minimal so the story text dominates the screen.
class SceneHeader extends ConsumerWidget {
  final Scene scene;

  const SceneHeader({super.key, required this.scene});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioState = ref.watch(audioControllerProvider);
    final storyState = ref.watch(storyControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Main row: title + audio pills
          Row(
            children: [
              // Scene title + mood
              Expanded(
                child: Row(
                  children: [
                    Text(
                      _moodEmoji(scene.sceneMood),
                      style: const TextStyle(fontSize: 18),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            scene.sceneSummary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium!
                                .copyWith(
                                  color: colorScheme.onSurface,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          Text(
                            '${scene.sceneMood} · ${scene.sceneEnergy} energy',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall!
                                .copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Compact audio pills
              _AudioPills(
                ambienceStatus: audioState.ambienceStatus,
                musicStatus: audioState.musicStatus,
                musicTheme: audioState.musicTheme,
                isListening: storyState.isListening,
              ),
            ],
          ),

          // Heard text strip (only when listening)
          if (storyState.isListening &&
              storyState.lastHeardText.isNotEmpty) ...[
            const SizedBox(height: 8),
            _HeardStrip(text: storyState.lastHeardText),
          ],
        ],
      ),
    );
  }

  String _moodEmoji(String mood) => switch (mood) {
        'mysterious' => '🌙',
        'joyful' => '🎉',
        'tense' => '⚡',
        'dramatic' => '🌊',
        'cozy' => '🔥',
        'awe' => '✨',
        _ => '📖',
      };
}

// ---------------------------------------------------------------------------
// Compact audio status pills row
// ---------------------------------------------------------------------------

class _AudioPills extends StatelessWidget {
  final AmbienceStatus ambienceStatus;
  final MusicStatus musicStatus;
  final String? musicTheme;
  final bool isListening;

  const _AudioPills({
    required this.ambienceStatus,
    required this.musicStatus,
    this.musicTheme,
    required this.isListening,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatusPill(
          icon: _ambienceIcon(ambienceStatus),
          color: _ambienceColor(ambienceStatus, context),
          isLoading: ambienceStatus == AmbienceStatus.loading,
        ),
        const SizedBox(width: 6),
        _StatusPill(
          icon: _musicIcon(musicStatus),
          color: _musicColor(musicStatus, context),
          isLoading: musicStatus == MusicStatus.loading,
        ),
        const SizedBox(width: 6),
        _StatusPill(
          icon: isListening ? Icons.mic_rounded : Icons.mic_off_rounded,
          color: isListening
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.onSurfaceVariant,
          isActive: isListening,
        ),
      ],
    );
  }

  IconData _ambienceIcon(AmbienceStatus s) => switch (s) {
        AmbienceStatus.loading => Icons.sync_rounded,
        AmbienceStatus.playing => Icons.graphic_eq_rounded,
        AmbienceStatus.error => Icons.error_outline_rounded,
        AmbienceStatus.idle => Icons.volume_off_rounded,
      };

  Color _ambienceColor(AmbienceStatus s, BuildContext ctx) {
    final cs = Theme.of(ctx).colorScheme;
    return switch (s) {
      AmbienceStatus.loading => cs.tertiary,
      AmbienceStatus.playing => cs.primary,
      AmbienceStatus.error => cs.error,
      AmbienceStatus.idle => cs.onSurfaceVariant,
    };
  }

  IconData _musicIcon(MusicStatus s) => switch (s) {
        MusicStatus.loading => Icons.sync_rounded,
        MusicStatus.playing => Icons.music_note_rounded,
        MusicStatus.error => Icons.error_outline_rounded,
        MusicStatus.idle => Icons.music_off_rounded,
      };

  Color _musicColor(MusicStatus s, BuildContext ctx) {
    final cs = Theme.of(ctx).colorScheme;
    return switch (s) {
      MusicStatus.loading => cs.tertiary,
      MusicStatus.playing => cs.secondary,
      MusicStatus.error => cs.error,
      MusicStatus.idle => cs.onSurfaceVariant,
    };
  }
}

/// Tiny circular pill — just an icon with a subtle background.
class _StatusPill extends StatelessWidget {
  final IconData icon;
  final Color color;
  final bool isLoading;
  final bool isActive;

  const _StatusPill({
    required this.icon,
    required this.color,
    this.isLoading = false,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withValues(alpha: isActive ? 0.2 : 0.1),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: isLoading
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: color,
                ),
              )
            : Icon(icon, size: 16, color: color),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Heard text strip
// ---------------------------------------------------------------------------

class _HeardStrip extends StatelessWidget {
  final String text;
  const _HeardStrip({required this.text});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.hearing_rounded,
              size: 14, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall!.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
