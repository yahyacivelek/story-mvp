import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/story_controller.dart';
import '../models/story_models.dart';

/// Fixed-width left sidebar listing all scenes.
class SceneSidebar extends ConsumerWidget {
  const SceneSidebar({super.key});

  static const double sidebarWidth = 260.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storyState = ref.watch(storyControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;

    if (storyState.isLoading) {
      return const SizedBox(
        width: sidebarWidth,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (storyState.storyData == null) {
      return const SizedBox(width: sidebarWidth);
    }

    final scenes = storyState.storyData!.sceneGraph;

    return Container(
      width: sidebarWidth,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          right: BorderSide(
            color: colorScheme.outlineVariant,
            width: 1,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SidebarHeader(storyData: storyState.storyData!),
          Expanded(
            child: ListView.builder(
              itemCount: scenes.length,
              itemBuilder: (context, index) {
                final scene = scenes[index];
                final isActive = storyState.activeSceneIndex == index;
                return _SceneTile(
                  scene: scene,
                  isActive: isActive,
                  onTap: () => ref
                      .read(storyControllerProvider.notifier)
                      .selectScene(index),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarHeader extends StatelessWidget {
  final StoryData storyData;

  const _SidebarHeader({required this.storyData});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_stories_rounded,
                  color: colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'SCENES',
                style: Theme.of(context).textTheme.labelSmall!.copyWith(
                      color: colorScheme.primary,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            storyData.title,
            style: Theme.of(context).textTheme.titleSmall!.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
          ),
          Text(
            storyData.book.language.toUpperCase(),
            style: Theme.of(context).textTheme.bodySmall!.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

class _SceneTile extends StatelessWidget {
  final Scene scene;
  final bool isActive;
  final VoidCallback onTap;

  const _SceneTile({
    required this.scene,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final moodEmoji = _moodEmoji(scene.sceneMood);

    return InkWell(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: isActive
              ? colorScheme.primaryContainer.withOpacity(0.5)
              : Colors.transparent,
          border: isActive
              ? Border(
                  left: BorderSide(
                    color: colorScheme.primary,
                    width: 3,
                  ),
                )
              : const Border(left: BorderSide(color: Colors.transparent, width: 3)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(moodEmoji, style: const TextStyle(fontSize: 14)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    scene.sceneId
                        .replaceAll('_', ' ')
                        .toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall!.copyWith(
                          color: isActive
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                          letterSpacing: 0.8,
                        ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              scene.sceneSummary,
              style: Theme.of(context).textTheme.bodySmall!.copyWith(
                    color: isActive
                        ? colorScheme.onSurface
                        : colorScheme.onSurfaceVariant,
                    fontWeight:
                        isActive ? FontWeight.w600 : FontWeight.normal,
                  ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _Tag(
                  label: scene.sceneMood,
                  color: colorScheme.tertiary,
                ),
                const SizedBox(width: 4),
                _Tag(
                  label: scene.sceneEnergy,
                  color: colorScheme.secondary,
                ),
              ],
            ),
          ],
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

class _Tag extends StatelessWidget {
  final String label;
  final Color color;

  const _Tag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall!.copyWith(
              color: color,
              fontSize: 10,
            ),
      ),
    );
  }
}
