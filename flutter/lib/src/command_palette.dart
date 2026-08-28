import 'package:flutter/material.dart' hide Key;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flterm/flterm.dart';

import 'terminal_connection.dart';

/// Opens the La-Terminal-style command palette over [context].
///
/// A searchable action sheet: type to filter, tap to run. Actions are drawn
/// from the connection plus global zuko operations, so the palette works
/// without a shell history source.
Future<void> showCommandPalette(
  BuildContext context, {
  required TerminalController controller,
  required TerminalConnection? connection,
  required VoidCallback onDisconnect,
  required VoidCallback onPair,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => CommandPalette(
      controller: controller,
      connection: connection,
      onDisconnect: onDisconnect,
      onPair: onPair,
    ),
  );
}

class CommandPalette extends StatefulWidget {
  const CommandPalette({
    super.key,
    required this.controller,
    required this.connection,
    required this.onDisconnect,
    required this.onPair,
  });

  final TerminalController controller;
  final TerminalConnection? connection;
  final VoidCallback onDisconnect;
  final VoidCallback onPair;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _PaletteAction {
  const _PaletteAction(this.label, this.icon, this.invoke);

  final String label;
  final IconData icon;
  final VoidCallback invoke;
}

class _CommandPaletteState extends State<CommandPalette> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final actions = <_PaletteAction>[
      _PaletteAction('Escape', Icons.keyboard_return, () {
        controller.sendKey(Key.escape);
      }),
      _PaletteAction('Tab', Icons.keyboard_tab, () {
        controller.sendKey(Key.tab);
      }),
      _PaletteAction('Ctrl+C', Icons.cancel_outlined, () {
        controller.toggleMod(const Mods.ctrl());
        controller.sendKey(Key.c);
      }),
      _PaletteAction('Ctrl+D', Icons.logout, () {
        controller.toggleMod(const Mods.ctrl());
        controller.sendKey(Key.d);
      }),
      _PaletteAction('Arrow up', Icons.keyboard_arrow_up, () {
        controller.sendKey(Key.arrowUp);
      }),
      _PaletteAction('Arrow down', Icons.keyboard_arrow_down, () {
        controller.sendKey(Key.arrowDown);
      }),
      _PaletteAction('Arrow left', Icons.keyboard_arrow_left, () {
        controller.sendKey(Key.arrowLeft);
      }),
      _PaletteAction('Arrow right', Icons.keyboard_arrow_right, () {
        controller.sendKey(Key.arrowRight);
      }),
      _PaletteAction('Home', Icons.first_page, () {
        controller.sendKey(Key.home);
      }),
      _PaletteAction('End', Icons.last_page, () {
        controller.sendKey(Key.end);
      }),
      _PaletteAction('Page up', Icons.keyboard_double_arrow_up, () {
        controller.sendKey(Key.pageUp);
      }),
      _PaletteAction('Page down', Icons.keyboard_double_arrow_down, () {
        controller.sendKey(Key.pageDown);
      }),
      _PaletteAction('Copy selection', Icons.copy, () async {
        final text = controller.selectedText();
        if (text.isEmpty) return;
        await Clipboard.setData(ClipboardData(text: text));
      }),
      _PaletteAction('Paste', Icons.paste, () async {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        if (data?.text == null || data!.text!.isEmpty) return;
        controller.paste(data.text!);
      }),
      _PaletteAction('Select all', Icons.select_all, controller.selectAll),
      if (widget.connection != null)
        _PaletteAction('Disconnect', Icons.link_off, () {
          widget.onDisconnect();
        }),
      _PaletteAction('Pair new host', Icons.add_link, () {
        widget.onPair();
      }),
    ];
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? actions
        : actions
              .where((action) => action.label.toLowerCase().contains(query))
              .toList(growable: false);

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Command search',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final action = filtered[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(action.icon, size: 20),
                      title: Text(action.label),
                      onTap: () {
                        action.invoke();
                        if (mounted) Navigator.of(context).pop();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
