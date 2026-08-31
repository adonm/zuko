import 'package:flterm/flterm.dart' show Key, TerminalController;
import 'package:flutter/material.dart' hide Key;
import 'package:flutter/scheduler.dart' show Ticker;

import 'repeatable_action.dart';

/// A translucent, draggable control pad that floats over the terminal on
/// touch platforms. It carries the keys the accessory bar drops there —
/// arrows, PgUp/PgDn, Home/End — plus scrollback control.
///
/// Interaction model:
/// - tap a key button to send that key (arrows repeat while held);
/// - touch the middle of the pad, hold, and drag to scroll the terminal;
/// - drag the padded border ring to reposition the pad.
/// A small floating logo button for touch layouts without a top bar; opens
/// the sidebar when no terminal (and therefore no pad) is visible yet.
class FloatingTerminalLogo extends StatelessWidget {
  const FloatingTerminalLogo({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Open sidebar',
      child: Semantics(
        button: true,
        label: 'Open sidebar',
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(20),
          child: Material(
            color: colors.surfaceContainerHighest.withValues(alpha: 0.44),
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Image.asset('assets/zuko-logo.png', width: 20, height: 20),
            ),
          ),
        ),
      ),
    );
  }
}

class FloatingTerminalPad extends StatelessWidget {
  const FloatingTerminalPad({
    super.key,
    required this.controller,
    required this.onScrollWheel,
    required this.onDragged,
    required this.onToggleSidebar,
  });

  final TerminalController controller;

  /// Forwards joystick scroll as wheel deltas; the app dispatches them over
  /// the terminal so flterm forwards to mouse-tracking programs or scrolls
  /// scrollback itself.
  final ValueChanged<double> onScrollWheel;
  final ValueChanged<Offset> onDragged;
  final VoidCallback onToggleSidebar;

  void _sendKey(Key key) => controller.sendKey(key);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const buttonSize = 38.0;
    return Material(
      color: colors.surfaceContainerHighest.withValues(alpha: 0.44),
      borderRadius: BorderRadius.circular(12),
      // The padded border ring repositions the pad; inner gestures stay
      // inside.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) => onDragged(details.delta),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PadButton(
                    size: buttonSize,
                    tooltip: 'Page Up',
                    icon: Icons.keyboard_double_arrow_up,
                    repeatable: true,
                    onPressed: () => _sendKey(Key.pageUp),
                  ),
                  _PadButton(
                    size: buttonSize,
                    tooltip: 'Up arrow',
                    icon: Icons.keyboard_arrow_up,
                    repeatable: true,
                    onPressed: () => _sendKey(Key.arrowUp),
                  ),
                  _PadButton(
                    size: buttonSize,
                    tooltip: 'Page Down',
                    icon: Icons.keyboard_double_arrow_down,
                    repeatable: true,
                    onPressed: () => _sendKey(Key.pageDown),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PadButton(
                    size: buttonSize,
                    tooltip: 'Left arrow',
                    icon: Icons.keyboard_arrow_left,
                    repeatable: true,
                    onPressed: () => _sendKey(Key.arrowLeft),
                  ),
                  _ScrollZone(
                    size: buttonSize,
                    onScrollWheel: onScrollWheel,
                    onToggleSidebar: onToggleSidebar,
                  ),
                  _PadButton(
                    size: buttonSize,
                    tooltip: 'Right arrow',
                    icon: Icons.keyboard_arrow_right,
                    repeatable: true,
                    onPressed: () => _sendKey(Key.arrowRight),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PadButton(
                    size: buttonSize,
                    tooltip: 'Home',
                    icon: Icons.first_page,
                    onPressed: () => _sendKey(Key.home),
                  ),
                  _PadButton(
                    size: buttonSize,
                    tooltip: 'Down arrow',
                    icon: Icons.keyboard_arrow_down,
                    repeatable: true,
                    onPressed: () => _sendKey(Key.arrowDown),
                  ),
                  _PadButton(
                    size: buttonSize,
                    tooltip: 'End',
                    icon: Icons.last_page,
                    onPressed: () => _sendKey(Key.end),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The pad's center: dragging here scrolls the terminal like a joystick —
/// the finger's displacement from where the drag started sets the scroll
/// speed, delivered as wheel events every frame so terminal programs can
/// handle them. A quick tap opens the sidebar.
class _ScrollZone extends StatefulWidget {
  const _ScrollZone({
    required this.size,
    required this.onScrollWheel,
    required this.onToggleSidebar,
  });

  final double size;
  final ValueChanged<double> onScrollWheel;
  final VoidCallback onToggleSidebar;

  @override
  State<_ScrollZone> createState() => _ScrollZoneState();
}

class _ScrollZoneState extends State<_ScrollZone>
    with SingleTickerProviderStateMixin {
  /// Full joystick deflection in logical pixels.
  static const _maxDisplacement = 110.0;

  /// Scroll speed in pixels per second at full deflection.
  static const _maxVelocity = 2400.0;

  late final Ticker _ticker = createTicker(_onTick);
  double _displacement = 0;
  Offset _origin = Offset.zero;
  Duration _lastElapsed = Duration.zero;
  bool _scrolling = false;

  void _start(Offset position) {
    _origin = position;
    _displacement = 0;
    _lastElapsed = Duration.zero;
    setState(() => _scrolling = true);
    _ticker.start();
  }

  void _update(Offset position) {
    _displacement = (position.dy - _origin.dy).clamp(
      -_maxDisplacement,
      _maxDisplacement,
    );
  }

  void _stop() {
    _ticker.stop();
    if (mounted) setState(() => _scrolling = false);
  }

  void _onTick(Duration elapsed) {
    if (_displacement == 0) {
      _lastElapsed = elapsed;
      return;
    }
    final velocity = _displacement / _maxDisplacement * _maxVelocity;
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    if (dt <= 0) return;
    // Wheel deltas let flterm route the scroll: mouse-tracking programs
    // receive encoded wheel reports, plain shells scroll scrollback.
    widget.onScrollWheel(velocity * dt);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      triggerMode: TooltipTriggerMode.manual,
      message: 'Drag to scroll, tap for menu',
      child: Semantics(
        button: true,
        label: 'Zuko menu, drag to scroll the terminal',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Tap opens the sidebar (touch devices have no top bar); dragging
          // scrolls like a joystick. The pan recognizer here beats the pad's
          // border-drag recognizer for touches starting in the middle, so
          // scrolling never repositions the pad.
          onTap: widget.onToggleSidebar,
          onPanStart: (details) {
            _start(details.globalPosition);
            _update(details.globalPosition);
          },
          onPanUpdate: (details) => _update(details.globalPosition),
          onPanEnd: (_) => _stop(),
          onPanCancel: _stop,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Center(
              child: Image.asset(
                'assets/zuko-logo.png',
                width: 18,
                height: 18,
                color: _scrolling ? colors.primary : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PadButton extends StatelessWidget {
  const _PadButton({
    required this.size,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.repeatable = false,
  });

  final double size;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool repeatable;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final content = SizedBox(
      width: size,
      height: size,
      child: Center(child: Icon(icon, size: 20, color: colors.onSurface)),
    );
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: repeatable
            ? RepeatableAction(
                onInvoke: onPressed,
                borderRadius: BorderRadius.circular(8),
                child: content,
              )
            : InkWell(
                onTap: onPressed,
                borderRadius: BorderRadius.circular(8),
                child: content,
              ),
      ),
    );
  }
}
