import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

bool pairingScannerSupported(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.macOS => true,
  _ => false,
};

enum PairingScannerError { permissionDenied, unsupported, unavailable }

class PairingScannerView extends StatefulWidget {
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
  State<PairingScannerView> createState() => _PairingScannerViewState();
}

class _PairingScannerViewState extends State<PairingScannerView>
    with WidgetsBindingObserver {
  late final MobileScannerController _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = MobileScannerController(
      autoStart: false,
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
    );
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  @override
  void didUpdateWidget(PairingScannerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      unawaited(_start());
    } else {
      unawaited(_controller.stop());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controller.value.hasCameraPermission) return;
    switch (state) {
      case AppLifecycleState.resumed:
        if (widget.active) unawaited(_start());
      case AppLifecycleState.inactive:
        unawaited(_controller.stop());
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        return;
    }
  }

  Future<void> _start() async {
    if (!mounted || !widget.active) return;
    try {
      await _controller.start();
    } on MobileScannerException {
      // MobileScanner's errorBuilder renders the actionable fallback.
    }
  }

  void _detected(BarcodeCapture capture) {
    if (!widget.active) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null) {
        widget.onDetect(value);
        return;
      }
    }
  }

  PairingScannerError _mapError(MobileScannerErrorCode code) => switch (code) {
    MobileScannerErrorCode.permissionDenied =>
      PairingScannerError.permissionDenied,
    MobileScannerErrorCode.unsupported => PairingScannerError.unsupported,
    _ => PairingScannerError.unavailable,
  };

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      MobileScanner(
        controller: _controller,
        onDetect: _detected,
        placeholderBuilder: (context) => const ColoredBox(
          color: Colors.black,
          child: Center(child: CircularProgressIndicator()),
        ),
        errorBuilder: (context, error) => ColoredBox(
          color: Colors.black,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                widget.errorMessage(_mapError(error.errorCode)),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
      ),
      PositionedDirectional(
        top: 12,
        end: 12,
        child: SafeArea(
          child: ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) => IconButton.filledTonal(
              tooltip: state.torchState == TorchState.on
                  ? 'Turn off flashlight'
                  : 'Turn on flashlight',
              onPressed:
                  widget.active &&
                      state.isRunning &&
                      state.torchState != TorchState.unavailable
                  ? _controller.toggleTorch
                  : null,
              icon: Icon(
                state.torchState == TorchState.on
                    ? Icons.flashlight_on
                    : Icons.flashlight_off,
              ),
            ),
          ),
        ),
      ),
    ],
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.dispose());
    super.dispose();
  }
}
