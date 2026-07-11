import 'package:flterm/flterm.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    await initializeForWeb(
      Uri.parse(
        'assets/packages/libghostty/assets/libghostty-wasm32-freestanding.wasm',
      ),
    );
  }
  final controller = await AppController.create();
  runApp(ZukoApp(controller: controller));
}
