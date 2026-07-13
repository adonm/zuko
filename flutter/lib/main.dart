import 'package:flterm/flterm.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:yaru/yaru.dart';

import 'src/bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
    await YaruWindowTitleBar.ensureInitialized();
  }
  if (kIsWeb) {
    MobileScannerPlatform.instance.setBarcodeLibraryScriptUrl(
      'vendor/zxing/index.min.js',
    );
    await initializeForWeb(
      Uri.parse(
        'assets/packages/libghostty/assets/libghostty-wasm32-freestanding.wasm',
      ),
    );
  }
  runApp(const ZukoBootstrap());
}
