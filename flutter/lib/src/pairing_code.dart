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
}
