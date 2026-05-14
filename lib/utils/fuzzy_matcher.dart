/// Lightweight fuzzy keyword matcher.
///
/// Scoring rules:
///  - Each primary keyword found in [transcript] → +2 points
///  - Each secondary keyword found in [transcript] → +1 point
///  - Partial word containment counts (e.g. transcript "once upon" matches
///    keyword "once")
///
/// Returns a normalised score 0.0–1.0 against [threshold].
class FuzzyMatcher {
  const FuzzyMatcher._();

  /// Returns `true` when the weighted keyword overlap in [transcript] meets
  /// [threshold] (0–1).
  ///
  /// [primaryKeywords] each contribute 2 points, [secondaryKeywords] 1 point.
  /// Score is normalised by the max possible points.
  static bool matches({
    required String transcript,
    required List<String> primaryKeywords,
    List<String> secondaryKeywords = const [],
    double threshold = 0.4,
  }) {
    return score(
          transcript: transcript,
          primaryKeywords: primaryKeywords,
          secondaryKeywords: secondaryKeywords,
        ) >=
        threshold;
  }

  static double score({
    required String transcript,
    required List<String> primaryKeywords,
    List<String> secondaryKeywords = const [],
  }) {
    if (primaryKeywords.isEmpty && secondaryKeywords.isEmpty) return 0.0;

    final t = transcript.toLowerCase();
    double earned = 0;
    double maxPoints = 0;

    for (final kw in primaryKeywords) {
      maxPoints += 2;
      if (_contains(t, kw.toLowerCase())) earned += 2;
    }
    for (final kw in secondaryKeywords) {
      maxPoints += 1;
      if (_contains(t, kw.toLowerCase())) earned += 1;
    }

    return maxPoints == 0 ? 0 : (earned / maxPoints).clamp(0.0, 1.0);
  }

  /// Checks whether [haystack] contains [needle] as a word or sub-word.
  static bool _contains(String haystack, String needle) {
    if (needle.isEmpty) return false;
    return haystack.contains(needle);
  }
}
