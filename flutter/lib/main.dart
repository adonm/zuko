import 'package:flterm/flterm.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    await initializeForWeb(
      Uri.parse(
        'assets/packages/libghostty/assets/libghostty-wasm32-freestanding.wasm',
      ),
    );
  }
  runApp(const ZukoBootstrap());
}
