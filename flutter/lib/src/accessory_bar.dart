import 'dart:async';

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart' hide Key;
import 'package:flutter/services.dart';
import 'package:yaru/yaru.dart';

import 'terminal_key_lists.dart';
import 'repeatable_action.dart';
import 'package:libghostty/libghostty.dart' show pasteIsSafe;
import 'theme.dart';

enum TerminalAccessoryMode {
  /// Full row: typing keys plus quick actions.
  full,

  /// Compact row: quick actions only, while the soft keyboard is closed.
  slim,
}

/// The mobile accessory shows typing keys above the open soft keyboard and
/// collapses to quick actions while it is closed. Desktop keeps the full row.
TerminalAccessoryMode terminalAccessoryMode({
  required bool keyboardVisible,
  required bool mobile,
}) => mobile && !keyboardVisible
    ? TerminalAccessoryMode.slim
    : TerminalAccessoryMode.full;

class TerminalAccessory extends StatefulWidget {
  const TerminalAccessory({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.showAdditionalKeys,
    required this.showKeyboard,
    required this.onShowKeyboardChanged,
  });
  final TerminalController controller;
  final FocusNode focusNode;
  final bool showAdditionalKeys;
  final bool showKeyboard;
  final ValueChanged<bool> onShowKeyboardChanged;

  @override
  State<TerminalAccessory> createState() => _TerminalAccessoryState();
}

class _TerminalAccessoryState extends State<TerminalAccessory> {
  TerminalController get controller => widget.controller;
  FocusNode get focusNode => widget.focusNode;
  bool get showKeyboard => widget.showKeyboard;

  final PageController _pageController = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _toggleKeyboard() {
    if (focusNode.hasFocus) {
      focusNode.unfocus();
      return;
    }
    // Enable keyboard presentation for this connection before focusing so
    // the platform text input attaches and the keyboard appears.
    if (!widget.showKeyboard) {
      widget.onShowKeyboardChanged(true);
    }
    focusNode.requestFocus();
  }

  void _showExtendedKeys() {
    _pageController.animateToPage(
      1,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

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
      focusNode.requestFocus();
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
      final keyboardActive = focusNode.hasFocus;
      final rowHeight = metrics.terminalAccessoryHeight;
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
              child: Stack(
                children: [
                  PageView(
                    controller: _pageController,
                    onPageChanged: (page) => setState(() => _page = page),
                    children: [
                      _MainKeyRow(
                        controller: controller,
                        focusNode: focusNode,
                        keyboardActive: keyboardActive,
                        onToggleKeyboard: _toggleKeyboard,
                        onCopy: () => _copy(context),
                        onPaste: () => _paste(context),
                        onExtendedKeys: _showExtendedKeys,
                      ),
                      _ExtendedKeyRow(controller: controller),
                    ],
                  ),
                  if (_page == 1)
                    Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2, right: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _PageDot(active: true),
                            const SizedBox(width: 4),
                            _PageDot(active: false),
                          ],
                        ),
                      ),
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
    child: Text(label),
  );
}

class _AccessoryIcon extends StatelessWidget {
  const _AccessoryIcon({
    required this.width,
    this.height,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected,
  });
  final double width;
  final double? height;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool? selected;

  @override
  Widget build(BuildContext context) => _AccessoryButton(
    width: width,
    height: height,
    tooltip: tooltip,
    selected: selected,
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
    final radius = BorderRadius.circular(kYaruButtonRadius);
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
              width: kYaruFocusBorderWidth,
            ),
            borderRadius: radius,
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            type: MaterialType.transparency,
            child: IconTheme(
              data: IconThemeData(
                color: foreground,
                size: metrics.size(kYaruIconSize),
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

class _AccessoryMenu extends StatelessWidget {
  const _AccessoryMenu({
    required this.width,
    this.height,
    required this.hasSelection,
    required this.onSelected,
  });

  final double width;
  final double? height;
  final bool hasSelection;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final metrics = ZukoMetrics.of(context);
    final itemHeight = height ?? metrics.terminalAccessoryHeight;
    return SizedBox(
      width: width,
      height: itemHeight,
      child: PopupMenuButton<String>(
        tooltip: 'More terminal actions',
        padding: EdgeInsets.zero,
        iconSize: metrics.size(kYaruIconSize),
        icon: const Icon(YaruIcons.view_more),
        style: ButtonStyle(
          fixedSize: WidgetStatePropertyAll(
            Size(width, metrics.terminalAccessoryHeight),
          ),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kYaruButtonRadius),
            ),
          ),
          foregroundColor: WidgetStatePropertyAll(
            colors.onSurface.withValues(alpha: 0.8),
          ),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return colors.onSurfaceVariant.withValues(alpha: 0.12);
            }
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return colors.onSurfaceVariant.withValues(alpha: 0.08);
            }
            return null;
          }),
        ),
        onSelected: onSelected,
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'extended-keys',
            child: _MenuAction(
              icon: YaruFreedesktopIcons.input_keyboard.icon,
              label: 'Extended keys',
            ),
          ),
          PopupMenuItem(
            value: 'tab',
            child: _MenuAction(icon: Icons.keyboard_tab, label: 'Tab key'),
          ),
          PopupMenuItem(
            value: 'select-all',
            child: _MenuAction(
              icon: YaruFreedesktopIcons.edit_select_all.icon,
              label: 'Select all',
            ),
          ),
          if (hasSelection)
            PopupMenuItem(
              value: 'copy',
              child: _MenuAction(
                icon: YaruFreedesktopIcons.edit_copy.icon,
                label: 'Copy',
              ),
            ),
          PopupMenuItem(
            value: 'paste',
            child: _MenuAction(
              icon: YaruFreedesktopIcons.edit_paste.icon,
              label: 'Paste',
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuAction extends StatelessWidget {
  const _MenuAction({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(label)],
  );
}

class _PageDot extends StatelessWidget {
  const _PageDot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active
            ? colors.primary
            : colors.onSurfaceVariant.withValues(alpha: 0.4),
      ),
    );
  }
}

class _MainKeyRow extends StatelessWidget {
  const _MainKeyRow({
    required this.controller,
    required this.focusNode,
    required this.keyboardActive,
    required this.onToggleKeyboard,
    required this.onCopy,
    required this.onPaste,
    required this.onExtendedKeys,
  });

  final TerminalController controller;
  final FocusNode focusNode;
  final bool keyboardActive;
  final VoidCallback onToggleKeyboard;
  final VoidCallback onCopy;
  final VoidCallback onPaste;
  final VoidCallback onExtendedKeys;

  @override
  Widget build(BuildContext context) {
    final metrics = ZukoMetrics.of(context);
    final itemWidth = metrics.terminalAccessoryItemWidth;
    final rowHeight = metrics.terminalAccessoryHeight;
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: metrics.size(6)),
      children: [
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
        SizedBox(width: metrics.terminalAccessoryGroupSpacing),
        for (final item in terminalArrowKeys)
          _RepeatableAccessoryIcon(
            width: itemWidth,
            height: rowHeight,
            tooltip: item.label,
            icon: terminalArrowIcon(item.key),
            onPressed: () => controller.sendKey(item.key),
          ),
        SizedBox(width: metrics.terminalAccessoryGroupSpacing),
        ListenableBuilder(
          listenable: focusNode,
          builder: (context, _) => _AccessoryIcon(
            width: itemWidth,
            height: rowHeight,
            tooltip: keyboardActive ? 'Hide keyboard' : 'Show keyboard',
            icon: keyboardActive
                ? YaruIcons.keyboard_filled
                : YaruFreedesktopIcons.input_keyboard.icon,
            selected: keyboardActive,
            onPressed: onToggleKeyboard,
          ),
        ),
        _AccessoryIcon(
          width: itemWidth,
          height: rowHeight,
          tooltip: controller.hasSelection ? 'Copy selected text' : 'Paste',
          icon: controller.hasSelection
              ? YaruFreedesktopIcons.edit_copy.icon
              : YaruFreedesktopIcons.edit_paste.icon,
          onPressed: controller.hasSelection ? onCopy : onPaste,
        ),
        _AccessoryMenu(
          width: itemWidth,
          height: rowHeight,
          hasSelection: controller.hasSelection,
          onSelected: (action) {
            switch (action) {
              case 'extended-keys':
                onExtendedKeys();
              case 'tab':
                controller.sendKey(Key.tab);
              case 'select-all':
                controller.selectAll();
              case 'copy':
                onCopy();
              case 'paste':
                onPaste();
            }
          },
        ),
      ],
    );
  }
}

class _ExtendedKeyRow extends StatelessWidget {
  const _ExtendedKeyRow({required this.controller});

  final TerminalController controller;

  @override
  Widget build(BuildContext context) {
    final metrics = ZukoMetrics.of(context);
    final itemWidth = metrics.terminalAccessoryItemWidth;
    final rowHeight = metrics.terminalAccessoryHeight;
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: metrics.size(6)),
      children: [
        for (final item in terminalNavigationKeys)
          _AccessoryKey(
            width: itemWidth,
            height: rowHeight,
            label: item.label,
            onPressed: () => controller.sendKey(item.key),
          ),
        SizedBox(width: metrics.terminalAccessoryGroupSpacing),
        for (final item in terminalFunctionKeys)
          _AccessoryKey(
            width: itemWidth,
            height: rowHeight,
            label: item.label,
            onPressed: () => controller.sendKey(item.key),
          ),
      ],
    );
  }
}
