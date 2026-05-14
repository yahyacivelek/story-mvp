import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/story_controller.dart';
import '../models/story_models.dart';
import '../widgets/interactive_text_widget.dart';
import '../widgets/scene_header.dart';
import '../widgets/scene_sidebar.dart';
import '../widgets/sfx_legend.dart';

/// The main application screen: sidebar + main content area.
class StoryScreen extends ConsumerWidget {
  const StoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storyState = ref.watch(storyControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;

    if (storyState.isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (storyState.error != null) {
      return Scaffold(
        body: Center(
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
                style: Theme.of(context).textTheme.bodySmall!.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLowest,
      body: Row(
        children: [
          const SceneSidebar(),
          Expanded(
            child: storyState.activeScene == null
                ? const SizedBox.shrink()
                : _SceneMainArea(
                    scene: storyState.activeScene!,
                    pages: storyState.activePagesContent,
                  ),
          ),
        ],
      ),
    );
  }
}

class _SceneMainArea extends StatelessWidget {
  final Scene scene;
  final List<StoryPage> pages;

  const _SceneMainArea({required this.scene, required this.pages});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SceneHeader(scene: scene),
        Expanded(
          child: _StoryBody(scene: scene, pages: pages),
        ),
        SfxLegend(opportunities: scene.audioOpportunities),
      ],
    );
  }
}

class _StoryBody extends StatelessWidget {
  final Scene scene;
  final List<StoryPage> pages;

  const _StoryBody({required this.scene, required this.pages});

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(48, 32, 48, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: pages.map((page) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PageNumberBadge(pageNumber: page.pageNumber),
                      const SizedBox(height: 16),
                      InteractiveTextWidget(
                        fullText: page.fullText,
                        opportunities: scene.audioOpportunities,
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

class _PageNumberBadge extends StatelessWidget {
  final int pageNumber;

  const _PageNumberBadge({required this.pageNumber});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withOpacity(0.4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'Page $pageNumber',
        style: Theme.of(context).textTheme.labelSmall!.copyWith(
              color: colorScheme.primary,
              letterSpacing: 0.8,
            ),
      ),
    );
  }
}
