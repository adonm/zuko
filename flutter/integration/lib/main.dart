// The integration test runner builds this package with the test file as the
// entrypoint; this main is never executed. It exists so the Linux runner has
// a stable build target.
import 'package:flutter/material.dart';

void main() => runApp(const MaterialApp(home: SizedBox.shrink()));
