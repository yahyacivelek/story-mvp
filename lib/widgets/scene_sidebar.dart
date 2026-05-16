import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/story_controller.dart';
import '../models/story_models.dart';

/// Modal bottom sheet listing all scenes — opens from the FAB.
class SceneSidebarSheet extends ConsumerWidget {
  const SceneSidebarSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storyState = ref.watch(storyControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;

    if (storyState.storyData == null) return const SizedBox.shrink();

    final scenes = storyState.storyData!.sceneGraph;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.65,
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
          _SheetHeader(storyData: storyState.storyData!),
          // Scene list
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: scenes.length,
              itemBuilder: (context, index) {
                final scene = scenes[index];
                final isActive = storyState.activeSceneIndex == index;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _SceneCard(
                    scene: scene,
                    index: index,
                    isActive: isActive,
                    onTap: () {
                      ref
                          .read(storyControllerProvider.notifier)
                          .selectScene(index);
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

class _SheetHeader extends StatelessWidget {
  final StoryData storyData;

  const _SheetHeader({required this.storyData});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Row(
        children: [
          Icon(Icons.auto_stories_rounded,
              color: colorScheme.primary, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  storyData.title,
                  style: Theme.of(context).textTheme.titleSmall!.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${storyData.sceneGraph.length} scenes · ${storyData.book.language.toUpperCase()}',
                  style: Theme.of(context).textTheme.bodySmall!.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SceneCard extends StatelessWidget {
  final Scene scene;
  final int index;
  final bool isActive;
  final VoidCallback onTap;

  const _SceneCard({
    required this.scene,
    required this.index,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final moodEmoji = _moodEmoji(scene.sceneMood);

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
              // Scene number circle
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
                      ? Icon(Icons.play_arrow_rounded,
                          size: 20, color: colorScheme.primary)
                      : Text(
                          '${index + 1}',
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium!
                              .copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                ),
              ),
              const SizedBox(width: 14),
              // Scene info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(moodEmoji, style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            scene.sceneSummary,
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
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _Chip(
                          label: scene.sceneMood,
                          color: colorScheme.tertiary,
                        ),
                        const SizedBox(width: 6),
                        _Chip(
                          label: scene.sceneEnergy,
                          color: colorScheme.secondary,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
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

class _Chip extends StatelessWidget {
  final String label;
  final Color color;

  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall!.copyWith(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
