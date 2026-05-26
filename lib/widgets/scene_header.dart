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
                          Row(
                            children: [
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
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Story picker chip
              if (storyState.manifest != null &&
                  storyState.manifest!.stories.length > 1)
                _StoryPickerChip(
                  currentEntry: storyState.currentStoryEntry,
                  stories: storyState.manifest!.stories,
                ),
              const SizedBox(width: 12),
              // Compact audio pills
              _AudioPills(
                ambienceStatus: audioState.ambienceStatus,
                musicStatus: audioState.musicStatus,
                musicTheme: audioState.musicTheme,
                isListening: storyState.isListening,
                ambienceEnabled: audioState.ambienceEnabled,
                musicEnabled: audioState.musicEnabled,
                onToggleAmbience: () {
                  final notifier =
                      ref.read(audioControllerProvider.notifier);
                  final enabling = !audioState.ambienceEnabled;
                  notifier.setAmbienceEnabled(
                    enabling,
                    scene: enabling ? scene : null,
                  );
                },
                onToggleMusicEnabled: () {
                  final notifier =
                      ref.read(audioControllerProvider.notifier);
                  final enabling = !audioState.musicEnabled;
                  notifier.setMusicEnabled(
                    enabling,
                    scene: enabling ? scene : null,
                  );
                },
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
  final bool ambienceEnabled;
  final bool musicEnabled;
  final VoidCallback onToggleAmbience;
  final VoidCallback onToggleMusicEnabled;

  const _AudioPills({
    required this.ambienceStatus,
    required this.musicStatus,
    this.musicTheme,
    required this.isListening,
    required this.ambienceEnabled,
    required this.musicEnabled,
    required this.onToggleAmbience,
    required this.onToggleMusicEnabled,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: ambienceEnabled ? 'Disable ambience' : 'Enable ambience',
          child: GestureDetector(
            onTap: onToggleAmbience,
            child: _StatusPill(
              icon: ambienceEnabled
                  ? _ambienceIcon(ambienceStatus)
                  : Icons.volume_off_rounded,
              color: ambienceEnabled
                  ? _ambienceColor(ambienceStatus, context)
                  : cs.onSurfaceVariant.withValues(alpha: 0.4),
              isLoading:
                  ambienceEnabled && ambienceStatus == AmbienceStatus.loading,
              isActive: ambienceEnabled,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Tooltip(
          message: musicEnabled ? 'Disable music' : 'Enable music',
          child: GestureDetector(
            onTap: onToggleMusicEnabled,
            child: _StatusPill(
              icon: musicEnabled
                  ? _musicIcon(musicStatus)
                  : Icons.music_off_rounded,
              color: musicEnabled
                  ? _musicColor(musicStatus, context)
                  : cs.onSurfaceVariant.withValues(alpha: 0.4),
              isLoading:
                  musicEnabled && musicStatus == MusicStatus.loading,
              isActive: musicEnabled,
            ),
          ),
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

// ---------------------------------------------------------------------------
// Story picker chip — taps to open story selection sheet
// ---------------------------------------------------------------------------

class _StoryPickerChip extends ConsumerWidget {
  final StoryEntry? currentEntry;
  final List<StoryEntry> stories;

  const _StoryPickerChip({
    required this.currentEntry,
    required this.stories,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: 'Switch story',
      child: GestureDetector(
        onTap: () => _showStorySheet(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: colorScheme.tertiaryContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_rounded,
                  size: 14, color: colorScheme.onTertiaryContainer),
              const SizedBox(width: 5),
              Text(
                currentEntry?.title ?? 'Select',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall!.copyWith(
                      color: colorScheme.onTertiaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.swap_horiz_rounded,
                  size: 12, color: colorScheme.onTertiaryContainer),
            ],
          ),
        ),
      ),
    );
  }

  void _showStorySheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StoryPickerSheet(
        currentEntry: currentEntry,
        stories: stories,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Story picker bottom sheet
// ---------------------------------------------------------------------------

class StoryPickerSheet extends ConsumerWidget {
  final StoryEntry? currentEntry;
  final List<StoryEntry> stories;

  const StoryPickerSheet({
    super.key,
    required this.currentEntry,
    required this.stories,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.5,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Row(
              children: [
                Icon(Icons.menu_book_rounded,
                    color: colorScheme.primary, size: 22),
                const SizedBox(width: 10),
                Text(
                  'Choose a Story',
                  style: Theme.of(context).textTheme.titleSmall!.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
          ),
          // Story list
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: stories.length,
              itemBuilder: (context, index) {
                final entry = stories[index];
                final isActive = currentEntry?.id == entry.id;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _StoryCard(
                    entry: entry,
                    isActive: isActive,
                    onTap: () {
                      debugPrint(
                          '[SceneHeader] story tap: "${entry.title}" '
                          'id=${entry.id} isActive=$isActive '
                          'currentId=${currentEntry?.id}');
                      if (!isActive) {
                        ref
                            .read(storyControllerProvider.notifier)
                            .loadStory(entry);
                      }
                      Navigator.of(context).pop();
                    },
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _StoryCard extends StatelessWidget {
  final StoryEntry entry;
  final bool isActive;
  final VoidCallback onTap;

  const _StoryCard({
    required this.entry,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: isActive
          ? colorScheme.primaryContainer.withValues(alpha: 0.4)
          : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isActive
                      ? colorScheme.primary.withValues(alpha: 0.2)
                      : colorScheme.surfaceContainerHigh,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: isActive
                      ? Icon(Icons.auto_stories_rounded,
                          size: 20, color: colorScheme.primary)
                      : Icon(Icons.menu_book_outlined,
                          size: 20, color: colorScheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium!
                          .copyWith(
                            color: isActive
                                ? colorScheme.primary
                                : colorScheme.onSurface,
                            fontWeight: isActive
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      entry.language.toUpperCase(),
                      style: Theme.of(context).textTheme.labelSmall!.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              if (isActive)
                Icon(Icons.check_circle_rounded,
                    size: 20, color: colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
