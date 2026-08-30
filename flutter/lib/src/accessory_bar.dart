import 'dart:async';

import 'package:flterm/flterm.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart' hide Key;
import 'package:flutter/services.dart';

import 'terminal_key_lists.dart';
import 'repeatable_action.dart';
import 'package:libghostty/libghostty.dart' show pasteIsSafe;
import 'theme.dart';

class TerminalAccessory extends StatefulWidget {
  const TerminalAccessory({
    super.key,
    required this.controller,
    this.showSidebarToggle = false,
    this.onToggleSidebar,
  });

  final TerminalController controller;
  final bool showSidebarToggle;
  final VoidCallback? onToggleSidebar;

  @override
  State<TerminalAccessory> createState() => _TerminalAccessoryState();
}

class _TerminalAccessoryState extends State<TerminalAccessory> {
  TerminalController get controller => widget.controller;

  void _showClipboardMessage(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copy(BuildContext context) async {
    try {
      final text = controller.selectedText();
      if (text.isEmpty) return;
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      _showClipboardMessage(context, 'Copied terminal selection');
    } on PlatformException {
      if (!context.mounted) return;
      _showClipboardMessage(context, 'Clipboard access was denied');
    }
  }

  Future<void> _paste(BuildContext context) async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null || text.isEmpty || !context.mounted) return;
      if (!pasteIsSafe(text)) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Paste potentially unsafe text?'),
            content: const Text(
              'The clipboard contains multiple lines or control characters. '
              'Pasting may execute commands immediately.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Paste'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }
      controller.paste(text);
    } on PlatformException {
      if (!context.mounted) return;
      _showClipboardMessage(context, 'Clipboard access was denied');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final metrics = ZukoMetrics.of(context);
      final rowHeight = metrics.terminalAccessoryHeight;
      final itemWidth = metrics.terminalAccessoryItemWidth;
      // On touch platforms the floating pad carries arrows and navigation
      // keys, so the accessory keeps only what the pad cannot.
      final padCoversNavigation = switch (defaultTargetPlatform) {
        TargetPlatform.iOS || TargetPlatform.android => true,
        _ => false,
      };
      return Material(
        color: colors.surfaceContainerLow,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: rowHeight,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: metrics.size(6)),
                children: [
                  if (widget.showSidebarToggle) ...[
                    _AccessoryLogo(
                      width: itemWidth,
                      height: rowHeight,
                      onPressed: widget.onToggleSidebar,
                    ),
                    SizedBox(width: metrics.terminalAccessoryGroupSpacing),
                  ],
                  _AccessoryKey(
                    width: itemWidth,
                    height: rowHeight,
                    label: 'Esc',
                    onPressed: () => controller.sendKey(Key.escape),
                  ),
                  _AccessoryKey(
                    width: itemWidth,
                    height: rowHeight,
                    label: 'Tab',
                    onPressed: () => controller.sendKey(Key.tab),
                  ),
                  SizedBox(width: metrics.terminalAccessoryGroupSpacing),
                  _AccessoryKey(
                    width: itemWidth,
                    height: rowHeight,
                    label: 'Ctrl',
                    selected: controller.virtualMods.hasCtrl,
                    onPressed: () => controller.toggleMod(const Mods.ctrl()),
                  ),
                  _AccessoryKey(
                    width: itemWidth,
                    height: rowHeight,
                    label: 'Alt',
                    selected: controller.virtualMods.hasAlt,
                    onPressed: () => controller.toggleMod(const Mods.alt()),
                  ),
                  if (!padCoversNavigation) ...[
                    SizedBox(width: metrics.terminalAccessoryGroupSpacing),
                    for (final item in terminalArrowKeys)
                      _RepeatableAccessoryIcon(
                        width: itemWidth,
                        height: rowHeight,
                        tooltip: item.label,
                        icon: terminalArrowIcon(item.key),
                        onPressed: () => controller.sendKey(item.key),
                      ),
                  ],
                  SizedBox(width: metrics.terminalAccessoryGroupSpacing),
                  _AccessoryIcon(
                    width: itemWidth,
                    height: rowHeight,
                    tooltip: controller.hasSelection
                        ? 'Copy selected text'
                        : 'Paste',
                    icon: controller.hasSelection
                        ? Icons.copy
                        : Icons.content_paste,
                    onPressed: controller.hasSelection
                        ? () => _copy(context)
                        : () => _paste(context),
                  ),
                  _AccessoryIcon(
                    width: itemWidth,
                    height: rowHeight,
                    tooltip: 'Select all',
                    icon: Icons.select_all,
                    onPressed: controller.selectAll,
                  ),
                  SizedBox(width: metrics.terminalAccessoryGroupSpacing),
                  for (final char in terminalPunctuationKeysFor(
                    defaultTargetPlatform,
                  ))
                    _AccessoryKey(
                      width: itemWidth,
                      height: rowHeight,
                      label: char,
                      onPressed: () => controller.sendText(char),
                    ),
                  if (!padCoversNavigation) ...[
                    SizedBox(width: metrics.terminalAccessoryGroupSpacing),
                    for (final item in terminalNavigationKeys)
                      _AccessoryKey(
                        width: itemWidth,
                        height: rowHeight,
                        label: item.label,
                        onPressed: () => controller.sendKey(item.key),
                      ),
                  ],
                  SizedBox(width: metrics.terminalAccessoryGroupSpacing),
                  for (final item in terminalFunctionKeys)
                    _AccessoryKey(
                      width: itemWidth,
                      height: rowHeight,
                      label: item.label,
                      onPressed: () => controller.sendKey(item.key),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _AccessoryKey extends StatelessWidget {
  const _AccessoryKey({
    required this.width,
    this.height,
    required this.label,
    required this.onPressed,
    this.selected,
  });
  final double width;
  final double? height;
  final String label;
  final VoidCallback onPressed;
  final bool? selected;

  @override
  Widget build(BuildContext context) => _AccessoryButton(
    width: width,
    height: height,
    tooltip: label,
    selected: selected,
    onPressed: onPressed,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(label, maxLines: 1, softWrap: false),
    ),
  );
}

class _AccessoryLogo extends StatelessWidget {
  const _AccessoryLogo({
    required this.width,
    this.height,
    required this.onPressed,
  });

  final double width;
  final double? height;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => _AccessoryButton(
    width: width,
    height: height,
    tooltip: 'Toggle sidebar',
    onPressed: onPressed,
    child: Image.asset('assets/zuko-logo.png', width: 18, height: 18),
  );
}

class _AccessoryIcon extends StatelessWidget {
  const _AccessoryIcon({
    required this.width,
    this.height,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });
  final double width;
  final double? height;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => _AccessoryButton(
    width: width,
    height: height,
    tooltip: tooltip,
    onPressed: onPressed,
    child: Icon(icon),
  );
}

class _RepeatableAccessoryIcon extends StatelessWidget {
  const _RepeatableAccessoryIcon({
    required this.width,
    this.height,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final double width;
  final double? height;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => _AccessoryButton(
    width: width,
    height: height,
    tooltip: tooltip,
    onPressed: onPressed,
    repeatable: true,
    child: Icon(icon),
  );
}

class _AccessoryButton extends StatefulWidget {
  const _AccessoryButton({
    required this.width,
    this.height,
    required this.tooltip,
    required this.onPressed,
    required this.child,
    this.selected,
    this.repeatable = false,
  });

  final double width;
  final double? height;
  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;
  final bool? selected;
  final bool repeatable;

  @override
  State<_AccessoryButton> createState() => _AccessoryButtonState();
}

class _AccessoryButtonState extends State<_AccessoryButton> {
  bool _focused = false;

  void _onFocusChange(bool focused) {
    if (_focused != focused) setState(() => _focused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final metrics = ZukoMetrics.of(context);
    final radius = BorderRadius.circular(kZukoButtonRadius);
    final foreground = widget.selected == true
        ? colors.primary
        : colors.onSurface.withValues(alpha: 0.8);
    final hoverColor = colors.onSurfaceVariant.withValues(alpha: 0.08);
    final pressedColor = colors.onSurfaceVariant.withValues(alpha: 0.12);
    final content = SizedBox(
      width: widget.width,
      height: widget.height ?? metrics.terminalAccessoryHeight,
      child: Center(child: widget.child),
    );
    final interactive = widget.repeatable
        ? RepeatableAction(
            onInvoke: widget.onPressed!,
            borderRadius: radius,
            focusColor: hoverColor,
            highlightColor: pressedColor,
            hoverColor: hoverColor,
            onFocusChange: _onFocusChange,
            child: content,
          )
        : InkWell(
            onTap: widget.onPressed,
            borderRadius: radius,
            focusColor: hoverColor,
            highlightColor: pressedColor,
            hoverColor: hoverColor,
            onFocusChange: _onFocusChange,
            child: content,
          );

    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        enabled: widget.onPressed != null,
        selected: widget.selected,
        label: widget.tooltip,
        excludeSemantics: true,
        child: AnimatedContainer(
          duration: Durations.short2,
          decoration: BoxDecoration(
            color: widget.selected == true
                ? colors.onSurface.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: radius,
          ),
          foregroundDecoration: BoxDecoration(
            border: Border.all(
              color: _focused ? colors.primary : Colors.transparent,
              width: kZukoFocusBorderWidth,
            ),
            borderRadius: radius,
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            type: MaterialType.transparency,
            child: IconTheme(
              data: IconThemeData(
                color: foreground,
                size: metrics.size(kZukoIconSize),
              ),
              child: DefaultTextStyle(
                style: Theme.of(context).textTheme.labelSmall!.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w500,
                  height: 1,
                ),
                child: interactive,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
