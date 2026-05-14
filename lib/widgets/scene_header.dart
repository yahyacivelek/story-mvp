import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/audio_controller.dart';
import '../controllers/story_controller.dart';
import '../models/story_models.dart';

/// Header panel shown above the story text area.
/// Displays scene summary, mood/energy tags, and ambience playback status.
class SceneHeader extends ConsumerWidget {
  final Scene scene;

  const SceneHeader({super.key, required this.scene});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioState = ref.watch(audioControllerProvider);
    final storyState = ref.watch(storyControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;

    final summaryColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          scene.sceneSummary,
          style: Theme.of(context).textTheme.headlineSmall!.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _Tag(
              icon: Icons.mood_rounded,
              label: scene.sceneMood,
              color: colorScheme.tertiary,
            ),
            _Tag(
              icon: Icons.bolt_rounded,
              label: '${scene.sceneEnergy} energy',
              color: colorScheme.secondary,
            ),
            _Tag(
              icon: Icons.menu_book_rounded,
              label: 'pages ${scene.pages.join(', ')}',
              color: colorScheme.primary,
            ),
          ],
        ),
      ],
    );

    final badges = Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _AmbienceStatusBadge(
          status: audioState.ambienceStatus,
          prompt: audioState.ambiencePrompt,
        ),
        _ListeningBadge(isListening: storyState.isListening),
      ],
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Adaptive: stack vertically on narrow screens (phones), side-by-side
          // on wide ones (tablet / desktop). The 560 px breakpoint matches the
          // sidebar-collapsed point so the layout stays sensible on every form
          // factor.
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 560;
              if (isNarrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    summaryColumn,
                    const SizedBox(height: 12),
                    badges,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: summaryColumn),
                  const SizedBox(width: 24),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _AmbienceStatusBadge(
                          status: audioState.ambienceStatus,
                          prompt: audioState.ambiencePrompt,
                        ),
                        const SizedBox(height: 8),
                        _ListeningBadge(isListening: storyState.isListening),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          if (storyState.isListening &&
              storyState.lastHeardText.isNotEmpty) ...[
            const SizedBox(height: 12),
            _HeardStrip(text: storyState.lastHeardText),
          ],
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _Tag({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall!.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _ListeningBadge extends StatelessWidget {
  final bool isListening;
  const _ListeningBadge({required this.isListening});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color =
        isListening ? colorScheme.error : colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isListening)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: color,
              ),
            )
          else
            Icon(Icons.mic_off_rounded, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            isListening ? 'Listening' : 'Mic off',
            style: Theme.of(context).textTheme.labelSmall!.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _HeardStrip extends StatelessWidget {
  final String text;
  const _HeardStrip({required this.text});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.hearing_rounded,
              size: 13, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
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

class _AmbienceStatusBadge extends StatelessWidget {
  final AmbienceStatus status;
  final String? prompt;

  const _AmbienceStatusBadge({required this.status, this.prompt});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final (IconData icon, String label, Color color) = switch (status) {
      AmbienceStatus.loading => (
          Icons.sync_rounded,
          'Loading ambience…',
          colorScheme.tertiary,
        ),
      AmbienceStatus.playing => (
          Icons.graphic_eq_rounded,
          'Ambience playing',
          colorScheme.primary,
        ),
      AmbienceStatus.error => (
          Icons.error_outline_rounded,
          'Audio error',
          colorScheme.error,
        ),
      AmbienceStatus.idle => (
          Icons.volume_off_rounded,
          'Ambience idle',
          colorScheme.onSurfaceVariant,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == AmbienceStatus.loading)
            SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: color,
              ),
            )
          else
            Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall!.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}
