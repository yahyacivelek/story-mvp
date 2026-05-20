import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/audio_controller.dart';
import '../controllers/story_controller.dart';
import '../models/story_models.dart';
import '../widgets/interactive_text_widget.dart';
import '../widgets/scene_header.dart';
import '../widgets/scene_sidebar.dart';

/// Immersive full-screen story reader.
///
/// Layout:
/// - Slim top bar: scene title + compact audio status pills
/// - Full-screen scrollable story text (the hero)
/// - Floating action button → opens scene picker as bottom sheet
/// - No permanent sidebar or footer — maximises reading area
class StoryScreen extends ConsumerWidget {
  const StoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storyState = ref.watch(storyControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;

    if (storyState.isLoading) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Loading story…',
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      );
    }

    if (storyState.error != null) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded,
                    color: colorScheme.error, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Failed to load story',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  storyState.error!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall!.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final scene = storyState.activeScene;
    final audioState = ref.watch(audioControllerProvider);
    final needsAudioUnlock = !audioState.playbackUnlocked;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: scene == null
          ? const SizedBox.shrink()
          : GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => ref
                  .read(audioControllerProvider.notifier)
                  .unlockPlayback(scene: scene),
              child: Stack(
              children: [
                // Main scrollable content
                SafeArea(
                  child: Column(
                    children: [
                      SceneHeader(scene: scene),
                      Expanded(
                        child: _StoryBody(
                          scene: scene,
                          pages: storyState.activePagesContent,
                        ),
                      ),
                    ],
                  ),
                ),

                if (needsAudioUnlock)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 88,
                    child: _AudioUnlockBanner(
                      onTap: () => ref
                          .read(audioControllerProvider.notifier)
                          .unlockPlayback(scene: scene),
                    ),
                  ),

                // Floating scene picker button
                Positioned(
                  right: 20,
                  bottom: 28,
                  child: _ScenePickerFab(
                    sceneCount:
                        storyState.storyData?.sceneGraph.length ?? 0,
                    activeIndex: storyState.activeSceneIndex,
                  ),
                ),
              ],
            ),
          ),
    );
  }
}

class _AudioUnlockBanner extends StatelessWidget {
  final VoidCallback onTap;

  const _AudioUnlockBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.primaryContainer.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(12),
      elevation: 4,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.touch_app_rounded, color: cs.onPrimaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Tap to enable ambience & music',
                  style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Story body — the hero of the screen
// ---------------------------------------------------------------------------

class _StoryBody extends ConsumerStatefulWidget {
  final Scene scene;
  final List<StoryPage> pages;

  const _StoryBody({required this.scene, required this.pages});

  @override
  ConsumerState<_StoryBody> createState() => _StoryBodyState();
}

class _StoryBodyState extends ConsumerState<_StoryBody> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      radius: const Radius.circular(4),
      controller: _scrollController,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 100),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widget.pages.map((page) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 48),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PageDivider(pageNumber: page.pageNumber),
                      const SizedBox(height: 20),
                      InteractiveTextWidget(
                        fullText: page.fullText,
                        opportunities: widget.scene.audioOpportunities,
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }
}

class _PageDivider extends StatelessWidget {
  final int pageNumber;

  const _PageDivider({required this.pageNumber});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 1,
            color: colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            '$pageNumber',
            style: Theme.of(context).textTheme.labelSmall!.copyWith(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  letterSpacing: 1,
                ),
          ),
        ),
        Expanded(
          child: Container(
            height: 1,
            color: colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Floating scene picker
// ---------------------------------------------------------------------------

class _ScenePickerFab extends ConsumerWidget {
  final int sceneCount;
  final int activeIndex;

  const _ScenePickerFab({
    required this.sceneCount,
    required this.activeIndex,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final storyState = ref.watch(storyControllerProvider);
    final storyName = storyState.currentStoryEntry?.title ?? 'Story';

    return FloatingActionButton.extended(
      backgroundColor: colorScheme.secondaryContainer,
      foregroundColor: colorScheme.onSecondaryContainer,
      elevation: 3,
      icon: const Icon(Icons.auto_stories_rounded, size: 20),
      label: Text('$storyName · Scene ${activeIndex + 1}/$sceneCount'),
      onPressed: () => _showSceneSheet(context, ref),
    );
  }

  void _showSceneSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const SceneSidebarSheet(),
    );
  }
}
