import 'package:flutter/material.dart';

bool pairingScannerSupported(TargetPlatform platform) => false;

class PairingScannerView extends StatelessWidget {
  const PairingScannerView({
    super.key,
    required this.active,
    required this.onDetect,
    required this.errorMessage,
  });

  final bool active;
  final ValueChanged<String> onDetect;
  final String Function(PairingScannerError error) errorMessage;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

enum PairingScannerError { permissionDenied, unsupported, unavailable }
