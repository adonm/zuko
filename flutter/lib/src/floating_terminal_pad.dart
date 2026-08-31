import 'package:flterm/flterm.dart' show Key, TerminalController;
import 'package:flutter/material.dart' hide Key;

import 'repeatable_action.dart';

/// A translucent, draggable control pad that floats over the terminal on
/// touch platforms. It carries the keys the accessory bar drops there —
/// arrows, PgUp/PgDn, Home/End — plus a center logo that opens the sidebar.
///
/// Interaction model:
/// - tap a key button to send that key (arrows repeat while held;
///   PgUp/PgDn scroll the terminal view);
/// - drag the pad to reposition it;
/// - tap the center logo to open the sidebar.
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
    required this.onDragged,
    required this.onToggleSidebar,
  });

  final TerminalController controller;
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
      // Dragging repositions the pad; button taps win the gesture arena.
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
                  _PadCenter(size: buttonSize, onPressed: onToggleSidebar),
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

/// The pad's center logo opens the sidebar. Touch layouts have no top bar,
/// and before any terminal opens the floating corner logo covers that case.
class _PadCenter extends StatelessWidget {
  const _PadCenter({required this.size, required this.onPressed});

  final double size;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Open sidebar',
      child: Semantics(
        button: true,
        label: 'Zuko menu',
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Image.asset('assets/zuko-logo.png', width: 18, height: 18),
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
