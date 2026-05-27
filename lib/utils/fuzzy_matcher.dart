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
      earned += 2 * _keywordHitFraction(t, kw.toLowerCase());
    }
    for (final kw in secondaryKeywords) {
      maxPoints += 1;
      earned += 1 * _keywordHitFraction(t, kw.toLowerCase());
    }

    return maxPoints == 0 ? 0 : (earned / maxPoints).clamp(0.0, 1.0);
  }

  /// Returns how strongly [keyword] is present in [transcript], in `[0, 1]`.
  ///
  /// Single-word keywords are binary (1.0 if contained, else 0.0).
  /// Multi-word phrases ("kalede ya\u015fard\u0131") tokenise and award the
  /// fraction of tokens found, so STT misrecognising one word in a phrase
  /// still contributes meaningful score instead of dropping to zero.
  static double _keywordHitFraction(String transcript, String keyword) {
    if (keyword.isEmpty) return 0.0;
    // Fast path: exact substring match wins full credit.
    if (transcript.contains(keyword)) return 1.0;

    final tokens = keyword
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.length <= 1) return 0.0;

    var hit = 0;
    for (final tok in tokens) {
      if (transcript.contains(tok)) hit++;
    }
    return hit / tokens.length;
  }
}
