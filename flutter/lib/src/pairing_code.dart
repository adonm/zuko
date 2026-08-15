final class PairingCode {
  const PairingCode._();

  static String? parse(String input) {
    var candidate = input.trim();
    if (candidate.length > 512 ||
        candidate.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      return null;
    }

    final uri = Uri.tryParse(candidate);
    if (uri != null && uri.hasScheme) {
      if (uri.scheme.toLowerCase() != 'zuko' ||
          uri.host.toLowerCase() != 'pair') {
        return null;
      }
      if (uri.pathSegments.isNotEmpty) {
        candidate = uri.pathSegments.join(' ');
      } else {
        String? code;
        for (final entry in uri.queryParameters.entries) {
          if (entry.key.toLowerCase() == 'code') code = entry.value;
        }
        candidate = code ?? '';
      }
    }

    candidate = candidate.trim().toLowerCase().replaceAll(
      RegExp(r'[-_\s]+'),
      '-',
    );
    if (candidate.length < 3 || candidate.length > 128) return null;
    if (!RegExp(r'^[a-z]+(?:-[a-z]+)+$').hasMatch(candidate)) return null;
    return candidate;
  }

  /// Finds the first pairing code inside free-form text, such as the
  /// combined output of `zuko share` (e.g. `zuko claim iridescent-hilton`).
  ///
  /// Returns a canonical code, or null when the text contains none.
  static String? extract(String text) {
    if (text.length > 4096) return null;
    final lower = text.toLowerCase();
    // A `zuko://pair/<code>` URI embedded in surrounding text.
    for (final match in RegExp(
      r'zuko://pair/[a-z]+(?:-[a-z]+)+',
    ).allMatches(lower)) {
      final code = parse(match.group(0)!);
      if (code != null) return code;
    }
    // The `zuko claim <code>` instruction printed by `zuko share`.
    for (final match in RegExp(
      r'zuko\s+claim\s+([a-z]+(?:-[a-z]+)+)',
    ).allMatches(lower)) {
      final code = parse(match.group(1)!);
      if (code != null) return code;
    }
    // A line that is exactly the code: the clean `zuko share` stdout line,
    // or merged stdout/stderr where the code sits on its own line.
    for (final match in RegExp(
      r'(?:^|[\r\n]+)[ \t]*([a-z]+[-_ ][a-z]+)[ \t]*[.,!?]?[ \t]*(?=[\r\n]|$)',
    ).allMatches(lower)) {
      final code = parse(match.group(1)!);
      if (code != null) return code;
    }
    // A labelled code from chat or notes, e.g. `code: iridescent-hilton`.
    for (final match in RegExp(
      r'(?:^|[\s])(?:share\s+)?code\s*[:=]\s*([a-z]+[-_ ][a-z]+)',
    ).allMatches(lower)) {
      final code = parse(match.group(1)!);
      if (code != null) return code;
    }
    return null;
  }
}
