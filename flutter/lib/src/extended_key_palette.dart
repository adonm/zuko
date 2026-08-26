import 'package:flterm/flterm.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart' hide Key;

import 'terminal_key_lists.dart';

Future<void> showTerminalExtendedKeyPalette(
  BuildContext context, {
  required ValueChanged<Key> onKey,
}) {
  void sendAndClose(BuildContext routeContext, Key key) {
    onKey(key);
    Navigator.of(routeContext).pop();
  }

  final useBottomSheet =
      !kIsWeb &&
      switch (defaultTargetPlatform) {
        TargetPlatform.android || TargetPlatform.iOS => true,
        _ => false,
      };
  if (useBottomSheet) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: TerminalExtendedKeyPalette(
          onKey: (key) => sendAndClose(sheetContext, key),
        ),
      ),
    );
  }

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close extended terminal keys',
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (dialogContext, _, _) => SafeArea(
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 32),
          child: Material(
            elevation: 8,
            color: Theme.of(dialogContext).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: SizedBox(
                width: MediaQuery.sizeOf(dialogContext).width - 16,
                child: TerminalExtendedKeyPalette(
                  onKey: (key) => sendAndClose(dialogContext, key),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween(begin: 0.96, end: 1.0).animate(animation),
        alignment: Alignment.bottomRight,
        child: child,
      ),
    ),
  );
}

class TerminalExtendedKeyPalette extends StatelessWidget {
  const TerminalExtendedKeyPalette({super.key, required this.onKey});

  final ValueChanged<Key> onKey;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Extended keys', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        _ExtendedKeyWrap(keys: terminalNavigationKeys, onKey: onKey),
        const SizedBox(height: 12),
        Text('Function keys', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        _ExtendedKeyWrap(keys: terminalFunctionKeys, onKey: onKey),
      ],
    ),
  );
}

class _ExtendedKeyWrap extends StatelessWidget {
  const _ExtendedKeyWrap({required this.keys, required this.onKey});

  final Iterable<({String label, Key key})> keys;
  final ValueChanged<Key> onKey;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = ((constraints.maxWidth - 16) / 3).clamp(72, 116).toDouble();
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final item in keys)
            SizedBox(
              width: width,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: () => onKey(item.key),
                child: Text(item.label, maxLines: 1),
              ),
            ),
        ],
      );
    },
  );
}
