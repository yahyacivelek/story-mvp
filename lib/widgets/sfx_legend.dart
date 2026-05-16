import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/audio_controller.dart';
import '../models/story_models.dart';

/// Footer legend listing all SFX triggers available in the current scene.
class SfxLegend extends ConsumerWidget {
  final List<AudioOpportunity> opportunities;

  const SfxLegend({super.key, required this.opportunities});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioState = ref.watch(audioControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;

    if (opportunities.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 20),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.touch_app_rounded,
                  size: 14, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'INTERACTIVE SOUNDS IN THIS SCENE',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelSmall!.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        letterSpacing: 1.2,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: opportunities
                .map((opp) => _SfxChip(
                      opportunity: opp,
                      isLoading:
                          audioState.isSfxLoading(opp.eventSummary),
                      onTap: () => ref
                          .read(audioControllerProvider.notifier)
                          .playSfx(opp),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _SfxChip extends StatelessWidget {
  final AudioOpportunity opportunity;
  final bool isLoading;
  final VoidCallback onTap;

  const _SfxChip({
    required this.opportunity,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: isLoading ? null : onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer.withOpacity(0.4),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: colorScheme.secondary.withOpacity(0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: colorScheme.secondary,
                ),
              )
            else
              Icon(
                Icons.surround_sound_rounded,
                size: 13,
                color: colorScheme.secondary,
              ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '"${opportunity.triggerAnchor.value}"',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: Theme.of(context).textTheme.labelSmall!.copyWith(
                      color: colorScheme.onSecondaryContainer,
                      fontStyle: FontStyle.italic,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
