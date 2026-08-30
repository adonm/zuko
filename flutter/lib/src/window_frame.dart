import 'package:flutter/material.dart';

bool usesIntegratedDesktopHeader({
  required bool wideLayout,
  required TargetPlatform platform,
  required bool isWeb,
}) =>
    wideLayout &&
    !isWeb &&
    switch (platform) {
      TargetPlatform.macOS || TargetPlatform.windows => true,
      _ => false,
    };

class ZukoAppTitle extends StatelessWidget {
  const ZukoAppTitle({super.key});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Image.asset('assets/zuko-logo.png', width: 26, height: 26),
      const SizedBox(width: 8),
      const Text('Zuko'),
    ],
  );
}
