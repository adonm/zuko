import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'model.dart';
import 'pairing_code.dart';
import 'pairing_scanner.dart';

typedef PairingScannerBuilder = Widget Function(
  BuildContext context,
  ValueChanged<String> onDetect,
);

String pairingClaimErrorMessage(Object error) {
  final text = error.toString().toLowerCase();
  if (error is FormatException && text.contains('enter the two-word code')) {
    return 'Enter the two-word code shown by zuko share.';
  }
  if (text.contains('expired') || text.contains('no longer available')) {
    return 'That share code is no longer available. Run zuko share again.';
  }
  if (text.contains('timed out') || text.contains('timeout')) {
    return 'Could not reach the host. Check that zuko share is still running.';
  }
  if (error is FormatException) {
    return 'The host returned invalid pairing information.';
  }
  return 'Could not pair with that host. Check the code and try again.';
}

String scannerErrorMessage(PairingScannerError errorCode) =>
    switch (errorCode) {
      PairingScannerError.permissionDenied =>
        'Camera permission was denied. Enter the share code instead.',
      PairingScannerError.unsupported =>
        'No supported camera is available. Enter the share code instead.',
      PairingScannerError.unavailable =>
        'The camera could not be started. Enter the share code instead.',
    };

bool supportsQrScanning({TargetPlatform? platform, bool? isWeb}) {
  if (isWeb ?? kIsWeb) return false;
  return pairingScannerSupported(platform ?? defaultTargetPlatform);
}

class PairingScreen extends StatefulWidget {
  const PairingScreen({
    super.key,
    required this.onClaim,
    this.claimErrorMessage,
    this.startInManual = false,
    this.scannerAvailable,
    this.scannerBuilder,
  });

  final Future<SavedHost> Function(String code) onClaim;
  final String Function(Object error)? claimErrorMessage;
  final bool startInManual;
  final bool? scannerAvailable;

  @visibleForTesting
  final PairingScannerBuilder? scannerBuilder;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _code = TextEditingController();
  final _codeFocus = FocusNode();
  late final bool _scannerAvailable;
  late bool _manual;
  int _scannerGeneration = 0;
  bool _submitting = false;
  bool _manualSubmitted = false;
  bool _paired = false;
  String? _pairedName;
  String? _message;
  String? _claimError;

  @override
  void initState() {
    super.initState();
    _scannerAvailable = widget.scannerAvailable ?? supportsQrScanning();
    _manual = widget.startInManual || !_scannerAvailable;
    _code.addListener(_codeChanged);
  }

  void _codeChanged() {
    if (!mounted) return;
    setState(() {
      _claimError = null;
    });
  }

  void _showManual() {
    if (!mounted) return;
    setState(() {
      _manual = true;
      _message = null;
      _claimError = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _codeFocus.requestFocus();
    });
  }

  void _showScanner() {
    if (!_scannerAvailable || _submitting) return;
    setState(() {
      _manual = false;
      _message = null;
      _claimError = null;
    });
  }

  void _restartScanner() {
    if (_submitting) return;
    setState(() {
      _message = null;
      _claimError = null;
      _scannerGeneration++;
    });
  }

  void _handleScannedValue(String value) {
    if (_submitting) return;
    final code = PairingCode.parse(value);
    if (code == null) {
      setState(() => _message = 'Not a Zuko pairing code. Keep scanning.');
      return;
    }
    unawaited(_claim(code));
  }

  Future<void> _submitManual() async {
    setState(() => _manualSubmitted = true);
    final code = PairingCode.parse(_code.text);
    if (code == null) return;
    await _claim(code);
  }

  Future<void> _claim(String code) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _message = null;
      _claimError = null;
    });
    try {
      final host = await widget.onClaim(code);
      if (!mounted) return;
      setState(() {
        _paired = true;
        _pairedName = host.name;
      });
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (mounted) Navigator.of(context).pop(host);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _claimError =
            widget.claimErrorMessage?.call(error) ??
            pairingClaimErrorMessage(error);
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _paste() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (text == null || text.isEmpty) return;
      // Be lenient with pasted text: the clipboard often holds the full
      // `zuko share` output rather than the bare code.
      final code = PairingCode.extract(text) ?? text;
      _code.value = TextEditingValue(
        text: code,
        selection: TextSelection.collapsed(offset: code.length),
      );
      if (PairingCode.parse(code) != null) {
        setState(() => _claimError = null);
        _codeFocus.requestFocus();
      }
    } on PlatformException {
      if (mounted) setState(() => _claimError = 'Clipboard access was denied.');
    }
  }

  String? _validateCode(String? value) {
    if (!_manualSubmitted && (value == null || value.isEmpty)) return null;
    return PairingCode.parse(value ?? '') == null
        ? 'Enter the two-word code shown by zuko share.'
        : null;
  }

  Widget _buildScanner(BuildContext context) {
    final injected = widget.scannerBuilder;
    if (injected != null) return injected(context, _handleScannedValue);
    return PairingScannerView(
      key: ValueKey(_scannerGeneration),
      active: !_submitting,
      onDetect: _handleScannedValue,
      errorMessage: scannerErrorMessage,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Pair a host')),
    body: Stack(
      fit: StackFit.expand,
      children: [
        if (_manual) _buildManual(context) else _buildCamera(context),
        if (_submitting)
          _paired ? _buildPairedOverlay() : _buildSubmittingOverlay(),
      ],
    ),
  );

  Widget _buildPairedOverlay() => ColoredBox(
    color: Colors.black.withValues(alpha: 0.55),
    child: Center(
      child: Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 56),
            const SizedBox(height: 16),
            Text(
              'Paired ${_pairedName ?? ''}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildSubmittingOverlay() => ColoredBox(
    color: Colors.black.withValues(alpha: 0.55),
    child: Center(
      child: Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text('Pairing…', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    ),
  );

  Widget _buildCamera(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      _buildScanner(context),
      const _ViewfinderOverlay(),
      Align(
        alignment: Alignment.bottomCenter,
        child: SafeArea(
          top: false,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            color: Theme.of(context).colorScheme.surface
                .withValues(alpha: 0.94),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Run zuko share on the host, then point the camera at its QR code.',
                  textAlign: TextAlign.center,
                ),
                if (_message != null) ...[
                  const SizedBox(height: 8),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _message!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                if (_claimError != null) ...[
                  const SizedBox(height: 8),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _claimError!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (_claimError != null)
                      FilledButton.icon(
                        onPressed: _submitting ? null : _restartScanner,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Scan again'),
                      ),
                    OutlinedButton.icon(
                      onPressed: _submitting ? null : _showManual,
                      icon: const Icon(Icons.keyboard_outlined),
                      label: const Text('Enter code instead'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  Widget _buildManual(BuildContext context) {
    final valid = PairingCode.parse(_code.text) != null;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.link,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Enter the share code',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Run zuko share on the host and enter its one-time two-word code.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _code,
                  focusNode: _codeFocus,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) {
                    if (valid && !_submitting) unawaited(_submitManual());
                  },
                  validator: _validateCode,
                  autovalidateMode: _manualSubmitted
                      ? AutovalidateMode.always
                      : AutovalidateMode.disabled,
                  decoration: InputDecoration(
                    labelText: 'Share code',
                    hintText: 'iridescent-hilton',
                    suffixIcon: IconButton(
                      tooltip: 'Paste share code',
                      onPressed: _submitting ? null : _paste,
                      icon: const Icon(Icons.content_paste),
                    ),
                  ),
                ),
                if (_claimError != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _claimError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: valid && !_submitting ? _submitManual : null,
                  icon: const Icon(Icons.link),
                  label: Text(_submitting ? 'Pairing…' : 'Pair'),
                ),
                if (_scannerAvailable) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _submitting ? null : _showScanner,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QR code'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _code.removeListener(_codeChanged);
    _code.dispose();
    _codeFocus.dispose();
    super.dispose();
  }
}

/// Renders the camera viewfinder: corner brackets with a sweeping scan
/// line that repeats while the scanner is active.
class _ViewfinderOverlay extends StatefulWidget {
  const _ViewfinderOverlay();

  @override
  State<_ViewfinderOverlay> createState() => _ViewfinderOverlayState();
}

class _ViewfinderOverlayState extends State<_ViewfinderOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scan = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _scan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Center(
      child: SizedBox(
        width: 260,
        height: 260,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: CustomPaint(painter: _ViewfinderPainter(_scan)),
        ),
      ),
    ),
  );
}

class _ViewfinderPainter extends CustomPainter {
  _ViewfinderPainter(this.animation) : super(repaint: animation);

  final Animation<double> animation;

  static const _inset = 12.0;
  static const _arm = 28.0;
  static const _stroke = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final corner = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round;

    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(_inset, _inset + _arm)
      ..lineTo(_inset, _inset)
      ..lineTo(_inset + _arm, _inset)
      ..moveTo(w - _inset - _arm, _inset)
      ..lineTo(w - _inset, _inset)
      ..lineTo(w - _inset, _inset + _arm)
      ..moveTo(w - _inset, h - _inset - _arm)
      ..lineTo(w - _inset, h - _inset)
      ..lineTo(w - _inset - _arm, h - _inset)
      ..moveTo(_inset + _arm, h - _inset)
      ..lineTo(_inset, h - _inset)
      ..lineTo(_inset, h - _inset - _arm);
    canvas.drawPath(path, corner);

    // Hairline frame connecting the brackets.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(_inset, _inset, w - 2 * _inset, h - 2 * _inset),
        Radius.circular(24 - _inset),
      ),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Sweeping scan line with a soft glow.
    final t = Curves.easeInOut.transform(animation.value);
    final y = 20.0 + t * (h - 40.0);
    final glow = Rect.fromLTWH(0, y - 14, w, 28);
    canvas.drawRect(
      glow,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Color(0x00FFFFFF), Color(0xCCFFFFFF), Color(0x00FFFFFF)],
          stops: [0.0, 0.5, 1.0],
        ).createShader(glow),
    );
    canvas.drawRect(
      Rect.fromLTWH(28, y - 1, w - 56, 2),
      Paint()..color = Colors.white,
    );

    // Subtle top/bottom inner shading for depth.
    final fade = Rect.fromLTWH(0, 0, w, 24);
    canvas.drawRect(
      fade,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x33000000), Color(0x00000000)],
        ).createShader(fade),
    );
    final fadeBottom = Rect.fromLTWH(0, h - 24, w, 24);
    canvas.drawRect(
      fadeBottom,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0x33000000)],
        ).createShader(fadeBottom),
    );
  }

  @override
  bool shouldRepaint(_ViewfinderPainter oldDelegate) =>
      oldDelegate.animation != animation;
}
