import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: scene == null
          ? const SizedBox.shrink()
          : Stack(
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
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) return;
    final progress = _scrollController.offset / maxScroll;
    ref.read(storyControllerProvider.notifier).onScrollProgress(progress);
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

    return FloatingActionButton.extended(
      backgroundColor: colorScheme.secondaryContainer,
      foregroundColor: colorScheme.onSecondaryContainer,
      elevation: 3,
      icon: const Icon(Icons.auto_stories_rounded, size: 20),
      label: Text('Scene ${activeIndex + 1}/$sceneCount'),
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
