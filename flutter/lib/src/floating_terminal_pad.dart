import 'dart:async';

import 'package:flterm/flterm.dart' show Key, TerminalController;
import 'package:flutter/material.dart' hide Key;

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
            color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
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
    required this.scrollController,
    required this.onDragged,
    required this.onToggleSidebar,
  });

  final TerminalController controller;
  final ScrollController scrollController;
  final ValueChanged<Offset> onDragged;
  final VoidCallback onToggleSidebar;

  void _sendKey(Key key) => controller.sendKey(key);

  void _scrollBy(double delta) {
    if (!scrollController.hasClients) return;
    final position = scrollController.position;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    unawaited(
      scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const buttonSize = 44.0;
    return Material(
      color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(14),
      // The padded border ring repositions the pad; inner gestures stay
      // inside.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) => onDragged(details.delta),
        child: Padding(
          padding: const EdgeInsets.all(8),
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
                    onScrollBy: _scrollBy,
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

/// The pad's center: holding and dragging here scrolls the terminal instead
/// of repositioning the pad.
class _ScrollZone extends StatefulWidget {
  const _ScrollZone({
    required this.size,
    required this.onScrollBy,
    required this.onToggleSidebar,
  });

  final double size;
  final ValueChanged<double> onScrollBy;
  final VoidCallback onToggleSidebar;

  @override
  State<_ScrollZone> createState() => _ScrollZoneState();
}

class _ScrollZoneState extends State<_ScrollZone> {
  bool _scrolling = false;

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
          // scrolls the terminal. The pan recognizer here beats the pad's
          // border-drag recognizer for touches starting in the middle, so
          // scrolling never repositions the pad.
          onTap: widget.onToggleSidebar,
          onPanStart: (_) => setState(() => _scrolling = true),
          onPanUpdate: (details) => widget.onScrollBy(details.delta.dy * 2.2),
          onPanEnd: (_) => setState(() => _scrolling = false),
          onPanCancel: () => setState(() => _scrolling = false),
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Center(
              child: Image.asset(
                'assets/zuko-logo.png',
                width: 22,
                height: 22,
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
