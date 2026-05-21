import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/audio_controller.dart';
import '../models/story_models.dart';

/// Renders a page's [fullText] as a [RichText] widget, splitting it around
/// any [AudioOpportunity.triggerAnchor.value] substrings.
///
/// Trigger words are rendered as inline tappable spans with a small audio
/// icon. While the SFX is fetching, a [CircularProgressIndicator] icon
/// replaces the audio icon inline.
class InteractiveTextWidget extends ConsumerWidget {
  final String fullText;
  final List<AudioOpportunity> opportunities;

  const InteractiveTextWidget({
    super.key,
    required this.fullText,
    required this.opportunities,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioState = ref.watch(audioControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final baseStyle = Theme.of(context).textTheme.bodyLarge!.copyWith(
          height: 1.8,
          color: colorScheme.onSurface,
        );

    return RichText(
      text: TextSpan(
        style: baseStyle,
        children: _buildSpans(context, ref, audioState, colorScheme, baseStyle),
      ),
    );
  }

  List<InlineSpan> _buildSpans(
    BuildContext context,
    WidgetRef ref,
    AudioState audioState,
    ColorScheme colorScheme,
    TextStyle baseStyle,
  ) {
    // Build a lookup: anchor text → AudioOpportunity
    final Map<String, AudioOpportunity> anchors = {
      for (final opp in opportunities) opp.triggerAnchor.value: opp,
    };

    if (anchors.isEmpty) {
      return [TextSpan(text: fullText)];
    }

    // Build a combined regex that matches any of the anchor strings.
    // Anchors are sorted longest-first to avoid partial-match ambiguities.
    final sortedAnchors = anchors.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    final pattern = sortedAnchors.map(RegExp.escape).join('|');
    // Case-insensitive match, allow optional trailing punctuation
    final regex = RegExp('($pattern)[\\s\\p{P}]*', caseSensitive: false);

    final spans = <InlineSpan>[];
    int cursor = 0;

    // Build case-insensitive lookup
    final lowerAnchors = <String, AudioOpportunity>{
      for (final entry in anchors.entries) entry.key.toLowerCase(): entry.value,
    };

    for (final match in regex.allMatches(fullText)) {
      // Text before the match.
      if (match.start > cursor) {
        spans.add(TextSpan(text: fullText.substring(cursor, match.start)));
      }

      final matchedText = match.group(0)!;  // Full match including punctuation
      final anchorKey = match.group(1)!;    // Just the anchor part (group 1)
      final opportunity = lowerAnchors[anchorKey.toLowerCase()]!;
      // Use matchedText for display (includes trailing punctuation that was in the text)
      final displayText = matchedText.trimRight();
      final isLoading = audioState.isSfxLoading(opportunity.eventSummary);

      spans.add(
        _buildTriggerSpan(
          anchor: displayText,
          opportunity: opportunity,
          isLoading: isLoading,
          ref: ref,
          colorScheme: colorScheme,
          baseStyle: baseStyle,
        ),
      );

      cursor = match.end;
    }

    // Remaining text after last match.
    if (cursor < fullText.length) {
      spans.add(TextSpan(text: fullText.substring(cursor)));
    }

    return spans;
  }

  InlineSpan _buildTriggerSpan({
    required String anchor,
    required AudioOpportunity opportunity,
    required bool isLoading,
    required WidgetRef ref,
    required ColorScheme colorScheme,
    required TextStyle baseStyle,
  }) {
    final highlightStyle = baseStyle.copyWith(
      color: colorScheme.primary,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.underline,
      decorationColor: colorScheme.primary.withOpacity(0.5),
    );

    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () {
            ref.read(audioControllerProvider.notifier).playSfx(opportunity);
          },
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 3,
            children: [
              Text(
                anchor,
                style: highlightStyle,
              ),
              if (isLoading)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: colorScheme.primary,
                  ),
                )
              else
                Icon(
                  Icons.volume_up_rounded,
                  size: 14,
                  color: colorScheme.primary.withOpacity(0.8),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
