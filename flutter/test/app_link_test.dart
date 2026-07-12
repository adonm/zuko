import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/app.dart';

void main() {
  test('terminal links allow absolute HTTP and HTTPS URLs', () {
    final http = Uri.parse('http://example.com/path');
    final https = Uri.parse('https://example.com/path?query=value');

    expect(supportedTerminalLink(http), http);
    expect(supportedTerminalLink(https), https);
  });

  test('terminal links reject unsupported and non-absolute URLs', () {
    for (final uri in [
      null,
      Uri.parse('/relative'),
      Uri.parse('https:path-without-host'),
      Uri.parse('file:///tmp/example'),
      Uri.parse('mailto:user@example.com'),
      Uri.parse('javascript:alert(1)'),
    ]) {
      expect(supportedTerminalLink(uri), isNull);
    }
  });
}
