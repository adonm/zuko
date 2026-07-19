import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';

bool usesYaruWindowTitleBar({
  required TargetPlatform platform,
  required bool isWeb,
}) => !isWeb && platform == TargetPlatform.linux;

bool usesIntegratedDesktopHeader({
  required bool wideLayout,
  required TargetPlatform platform,
  required bool isWeb,
}) =>
    usesYaruWindowTitleBar(platform: platform, isWeb: isWeb) ||
    (wideLayout &&
        !isWeb &&
        switch (platform) {
          TargetPlatform.macOS || TargetPlatform.windows => true,
          _ => false,
        });

class ZukoWindowFrame extends StatelessWidget {
  const ZukoWindowFrame({super.key, required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final content = child ?? const SizedBox.shrink();
    if (!usesYaruWindowTitleBar(
      platform: defaultTargetPlatform,
      isWeb: kIsWeb,
    )) {
      return content;
    }
    return Column(
      children: [
        const YaruWindowTitleBar(title: ZukoAppTitle()),
        Expanded(child: content),
      ],
    );
  }
}

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
