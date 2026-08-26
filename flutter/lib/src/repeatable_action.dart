import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;

class RepeatableAction extends StatefulWidget {
  const RepeatableAction({
    super.key,
    required this.onInvoke,
    required this.child,
    this.initialDelay = const Duration(milliseconds: 400),
    this.repeatInterval = const Duration(milliseconds: 80),
    this.borderRadius,
    this.focusColor,
    this.highlightColor,
    this.hoverColor,
    this.onFocusChange,
  });

  final VoidCallback onInvoke;
  final Widget child;
  final Duration initialDelay;
  final Duration repeatInterval;
  final BorderRadius? borderRadius;
  final Color? focusColor;
  final Color? highlightColor;
  final Color? hoverColor;
  final ValueChanged<bool>? onFocusChange;

  @override
  State<RepeatableAction> createState() => _RepeatableActionState();
}

class _RepeatableActionState extends State<RepeatableAction> {
  Timer? _delayTimer;
  Timer? _repeatTimer;
  int? _activePointer;
  bool _pointerTap = false;

  void _start(PointerDownEvent event) {
    if (_activePointer != null || event.buttons != kPrimaryButton) return;
    _activePointer = event.pointer;
    _pointerTap = true;
    widget.onInvoke();
    _delayTimer = Timer(widget.initialDelay, () {
      if (_activePointer == null) return;
      widget.onInvoke();
      _repeatTimer = Timer.periodic(
        widget.repeatInterval,
        (_) => widget.onInvoke(),
      );
    });
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _activePointer) return;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      _cancel(event);
      return;
    }
    final renderBox = renderObject;
    if (!renderBox.size.contains(event.localPosition)) _cancel();
  }

  void _finish(PointerEvent event) {
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    _stopTimers();
  }

  void _cancel([PointerEvent? event]) {
    if (event != null && event.pointer != _activePointer) return;
    _activePointer = null;
    _pointerTap = false;
    _stopTimers();
  }

  void _stopTimers() {
    _delayTimer?.cancel();
    _repeatTimer?.cancel();
    _delayTimer = null;
    _repeatTimer = null;
  }

  void _tap() {
    if (!_pointerTap) widget.onInvoke();
    _pointerTap = false;
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onExit: _cancel,
    child: Listener(
      onPointerDown: _start,
      onPointerMove: _move,
      onPointerUp: _finish,
      onPointerCancel: _cancel,
      child: InkResponse(
        onTap: _tap,
        onTapCancel: _cancel,
        borderRadius: widget.borderRadius,
        containedInkWell: true,
        focusColor: widget.focusColor,
        highlightColor: widget.highlightColor,
        hoverColor: widget.hoverColor,
        onFocusChange: widget.onFocusChange,
        child: widget.child,
      ),
    ),
  );

  @override
  void dispose() {
    _stopTimers();
    super.dispose();
  }
}

double effectiveTerminalFontSize({
  required bool wideLayout,
  required double configuredSize,
  required bool customized,
}) {
  if (customized) return configuredSize;
  return wideLayout ? 10 : 7;
}

Uri? supportedTerminalLink(Uri? uri) {
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  return switch (uri.scheme.toLowerCase()) {
    'http' || 'https' => uri,
    _ => null,
  };
}
