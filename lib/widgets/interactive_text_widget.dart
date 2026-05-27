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
///
/// Additionally:
/// - [cueKeywords] (entry/exit scene-transition words) → amber background
/// - AO voice trigger primary_keywords → green background
class InteractiveTextWidget extends ConsumerWidget {
  final String fullText;
  final List<AudioOpportunity> opportunities;
  /// Character offset up to which text has been read aloud (karaoke highlight).
  /// 0 means nothing highlighted yet.
  final int readUpToCharOffset;
  /// Entry + exit cue keywords for the active scene (shown with amber background).
  final Set<String> cueKeywords;

  const InteractiveTextWidget({
    super.key,
    required this.fullText,
    required this.opportunities,
    this.readUpToCharOffset = 0,
    this.cueKeywords = const {},
  });

  /// Collects all voice-trigger primary keywords from [opportunities] whose
  /// anchor type is NOT phrase/word (i.e. page_start) — those won't appear
  /// as tappable anchors so we highlight their keywords instead.
  Set<String> _aoVoiceKeywords() {
    final result = <String>{};
    for (final ao in opportunities) {
      for (final kw in ao.triggerPrimaryKeywords) {
        result.add(kw.toLowerCase());
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioState = ref.watch(audioControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final baseStyle = Theme.of(context).textTheme.bodyLarge!.copyWith(
          height: 1.8,
          color: colorScheme.onSurface,
        );

    final readStyle = baseStyle.copyWith(
      color: colorScheme.onSurface.withValues(alpha: 0.38),
      background: Paint()
        ..color = colorScheme.primary.withValues(alpha: 0.08),
    );

    final cueStyle = baseStyle.copyWith(
      fontWeight: FontWeight.w600,
      background: Paint()
        ..color = Colors.amber.withValues(alpha: 0.35),
    );

    final aoKwStyle = baseStyle.copyWith(
      fontWeight: FontWeight.w600,
      background: Paint()
        ..color = Colors.green.withValues(alpha: 0.25),
    );

    return RichText(
      text: TextSpan(
        style: baseStyle,
        children: _buildSpans(
          context, ref, audioState, colorScheme,
          baseStyle, readStyle, cueStyle, aoKwStyle,
        ),
      ),
    );
  }

  List<InlineSpan> _buildSpans(
    BuildContext context,
    WidgetRef ref,
    AudioState audioState,
    ColorScheme colorScheme,
    TextStyle baseStyle,
    TextStyle readStyle,
    TextStyle cueStyle,
    TextStyle aoKwStyle,
  ) {
    // Build a lookup: anchor text → AudioOpportunity (phrase/word anchors only)
    final Map<String, AudioOpportunity> anchors = {};
    for (final opp in opportunities) {
      final t = opp.triggerAnchor.type;
      if (t == 'phrase' || t == 'word') {
        anchors[opp.triggerAnchor.value] = opp;
      }
    }

    // Combine all highlight tokens: anchors + cue keywords + AO voice keywords.
    // Priority: anchor > cue > ao_keyword (longer match wins via sort).
    final aoVoiceKws = _aoVoiceKeywords();
    final lowerCue = {for (final k in cueKeywords) k.toLowerCase()};

    final allTokens = <String>{
      ...anchors.keys,
      ...lowerCue,
      ...aoVoiceKws,
    }.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    if (allTokens.isEmpty) {
      return _splitAtOffset(fullText, 0, readStyle, baseStyle);
    }

    final pattern = allTokens.map(RegExp.escape).join('|');
    final regex = RegExp('($pattern)', caseSensitive: false, unicode: true);

    final spans = <InlineSpan>[];
    int cursor = 0;

    final lowerAnchors = <String, AudioOpportunity>{
      for (final entry in anchors.entries) entry.key.toLowerCase(): entry.value,
    };

    for (final match in regex.allMatches(fullText)) {
      if (match.start > cursor) {
        final segment = fullText.substring(cursor, match.start);
        spans.addAll(_splitAtOffset(segment, cursor, readStyle, baseStyle));
      }

      final matchedText = match.group(1)!;
      final key = matchedText.toLowerCase();

      if (lowerAnchors.containsKey(key)) {
        // Tappable SFX anchor — existing behaviour
        final opportunity = lowerAnchors[key]!;
        final isLoading = audioState.isSfxLoading(opportunity.eventSummary);
        spans.add(_buildTriggerSpan(
          anchor: matchedText,
          opportunity: opportunity,
          isLoading: isLoading,
          ref: ref,
          colorScheme: colorScheme,
          baseStyle: baseStyle,
        ));
      } else if (lowerCue.contains(key)) {
        // Scene-transition cue keyword — amber highlight
        spans.add(TextSpan(text: matchedText, style: cueStyle));
      } else {
        // AO voice trigger keyword — green highlight
        spans.add(TextSpan(text: matchedText, style: aoKwStyle));
      }

      cursor = match.end;
    }

    if (cursor < fullText.length) {
      final segment = fullText.substring(cursor);
      spans.addAll(_splitAtOffset(segment, cursor, readStyle, baseStyle));
    }

    return spans;
  }

  /// Splits [segment] (which starts at [segmentStart] in [fullText]) into at
  /// most two [TextSpan]s: the part before [readUpToCharOffset] uses
  /// [readStyle]; the rest uses [normalStyle].
  List<TextSpan> _splitAtOffset(
    String segment,
    int segmentStart,
    TextStyle readStyle,
    TextStyle normalStyle,
  ) {
    if (readUpToCharOffset <= segmentStart) {
      return [TextSpan(text: segment, style: normalStyle)];
    }
    final splitLocal = (readUpToCharOffset - segmentStart).clamp(0, segment.length);
    if (splitLocal >= segment.length) {
      return [TextSpan(text: segment, style: readStyle)];
    }
    return [
      TextSpan(text: segment.substring(0, splitLocal), style: readStyle),
      TextSpan(text: segment.substring(splitLocal), style: normalStyle),
    ];
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
      decorationColor: colorScheme.primary.withValues(alpha: 0.5),
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
