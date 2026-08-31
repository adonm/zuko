import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'model.dart';
import 'session_state.dart';
import 'theme.dart';
import 'client_name.dart';

Future<String?> showDeviceNameDialog(
  BuildContext context, {
  required String initialName,
}) => showDialog<String>(
  context: context,
  builder: (context) => DeviceNameDialog(initialName: initialName),
);

class DeviceNameDialog extends StatefulWidget {
  const DeviceNameDialog({super.key, required this.initialName});

  final String initialName;

  @override
  State<DeviceNameDialog> createState() => _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<DeviceNameDialog> {
  late final TextEditingController _name;
  String? errorText;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
  }

  void _submit() {
    final normalized = normalizeClientName(_name.text);
    if (normalized.isEmpty) {
      setState(() => errorText = 'Enter letters or numbers.');
    } else {
      Navigator.pop(context, normalized);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('This device name'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            autocorrect: false,
            maxLength: maxClientNameLength,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Device name',
              errorText: errorText,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          const Text(
            'Used for new host authorizations. Re-pair a saved host to '
            'update its existing label.',
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Save')),
    ],
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }
}

class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.expanded,
    required this.onToggle,
    required this.onPair,
    required this.showPairAction,
    required this.child,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onPair;
  final bool showPairAction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final metrics = ZukoMetrics.of(context);
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: expanded ? metrics.sidebarWidth : metrics.collapsedSidebarWidth,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: expanded
              ? Column(
                  children: [
                    SizedBox(
                      height: metrics.sidebarHeaderHeight,
                      child: Padding(
                        padding: EdgeInsetsDirectional.only(
                          start: metrics.size(16),
                          end: metrics.size(6),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Connections',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            IconButton(
                              onPressed: onToggle,
                              tooltip: 'Collapse sidebar',
                              icon: const Icon(Icons.chevron_left),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(child: child),
                  ],
                )
              : Column(
                  children: [
                    SizedBox(
                      height: metrics.sidebarHeaderHeight,
                      child: IconButton(
                        onPressed: onToggle,
                        tooltip: 'Expand sidebar',
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ),
                    const Divider(height: 1),
                    if (showPairAction) ...[
                      SizedBox(height: metrics.size(6)),
                      IconButton(
                        onPressed: onPair,
                        tooltip: 'Pair a new host',
                        icon: const Icon(Icons.add_link),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.controller,
    required this.terminalFontSize,
    required this.selected,
    required this.sessionState,
    required this.openConnectionCount,
    required this.onPair,
    required this.onConnect,
    required this.onDisconnect,
    required this.onForget,
  });

  final AppController controller;
  final double terminalFontSize;
  final SavedHost? selected;
  final SessionState sessionState;
  final int openConnectionCount;
  final Future<void> Function() onPair;
  final ValueChanged<SavedHost> onConnect;
  final VoidCallback onDisconnect;
  final Future<void> Function(SavedHost host) onForget;

  Future<void> _copy(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Copied')));
    }
  }

  Future<void> _details(BuildContext context, SavedHost host) async {
    final clientLabel = host.authorizedClientLabel;
    final revokeCommand = clientLabel == null ? null : 'zuko rm $clientLabel';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(host.name),
        content: SelectionArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Host label: ${host.label}'),
              const SizedBox(height: 8),
              Text('Node ID: ${host.nodeId}'),
              const SizedBox(height: 16),
              if (revokeCommand != null) ...[
                const Text('To revoke this client, run on the host:'),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(child: Text(revokeCommand)),
                    IconButton(
                      tooltip: 'Copy revoke command',
                      onPressed: () => _copy(context, revokeCommand),
                      icon: const Icon(Icons.copy),
                    ),
                  ],
                ),
              ] else
                const Text(
                  'This host was saved by an older app version. Pair again '
                  'to record the exact host-side client label for revocation.',
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, SavedHost host) async {
    final name = TextEditingController(text: host.name);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename host'),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (accepted == true) await controller.rename(host, name.text);
    name.dispose();
  }

  Future<void> _editClientName(BuildContext context) async {
    final updated = await showDeviceNameDialog(
      context,
      initialName: controller.clientName,
    );
    if (updated != null) await controller.setClientName(updated);
  }

  Future<void> _confirmForget(BuildContext context, SavedHost host) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Forget ${host.name}?'),
        content: const Text(
          'This removes the host from this client only. It does not revoke '
          'this client on the host.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (accepted == true) await onForget(host);
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
    ),
    child: ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const SizedBox(height: 2),
        if (controller.hosts.isNotEmpty) ...[
          FilledButton.icon(
            onPressed: controller.busy ? null : onPair,
            icon: const Icon(Icons.add_link),
            label: const Text('Pair host'),
          ),
          const SizedBox(height: 18),
        ],
        SectionLabel('Saved hosts (${controller.hosts.length})'),
        const SizedBox(height: 8),
        if (controller.hosts.isEmpty)
          const Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(Icons.computer_outlined),
              title: Text('No saved hosts'),
              subtitle: Text('Pair your first host from the welcome screen.'),
            ),
          ),
        if (controller.hosts.isNotEmpty)
          SavedHostList(
            hosts: controller.hosts,
            selected: selected,
            onConnect: onConnect,
            onAction: (action, host) {
              switch (action) {
                case 'details':
                  unawaited(_details(context, host));
                case 'rename':
                  unawaited(_rename(context, host));
                case 'forget':
                  unawaited(_confirmForget(context, host));
              }
            },
          ),
        const SizedBox(height: 24),
        const SectionLabel('Appearance'),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              OptionTile<AppThemePreference>(
                icon: Icons.palette_outlined,
                label: 'Color scheme',
                value: controller.theme,
                valueLabel: (value) => switch (value) {
                  AppThemePreference.system => 'System',
                  AppThemePreference.dark => 'Dark',
                  AppThemePreference.light => 'Light',
                },
                items: const [
                  (value: AppThemePreference.system, label: 'System'),
                  (value: AppThemePreference.dark, label: 'Dark'),
                  (value: AppThemePreference.light, label: 'Light'),
                ],
                onSelected: (value) => unawaited(controller.setTheme(value)),
              ),
              const Divider(indent: 42),
              OptionTile<AppInterfaceSize>(
                icon: Icons.aspect_ratio_outlined,
                label: 'Interface size',
                value: controller.interfaceSize,
                valueLabel: (value) => switch (value) {
                  AppInterfaceSize.compact => 'Compact',
                  AppInterfaceSize.standard => 'Default',
                  AppInterfaceSize.comfortable => 'Comfortable',
                },
                items: const [
                  (value: AppInterfaceSize.compact, label: 'Compact'),
                  (value: AppInterfaceSize.standard, label: 'Default'),
                  (value: AppInterfaceSize.comfortable, label: 'Comfortable'),
                ],
                onSelected: (value) =>
                    unawaited(controller.setInterfaceSize(value)),
              ),
              const Divider(indent: 42),
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Row(
                  children: [
                    const Icon(Icons.text_fields, size: 20),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('Terminal text')),
                    IconButton(
                      tooltip: 'Decrease font size',
                      onPressed: terminalFontSize <= 5
                          ? null
                          : () => unawaited(
                              controller.setTerminalFontSize(
                                terminalFontSize - 1,
                              ),
                            ),
                      icon: const Icon(Icons.remove),
                    ),
                    SizedBox(
                      width: 24,
                      child: Text(
                        '${terminalFontSize.round()}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Increase font size',
                      onPressed: terminalFontSize >= 20
                          ? null
                          : () => unawaited(
                              controller.setTerminalFontSize(
                                terminalFontSize + 1,
                              ),
                            ),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
              ),
              const Divider(indent: 42),
              SwitchListTile(
                secondary: const Icon(Icons.keyboard_alt_outlined, size: 20),
                title: const Text('Open keyboard on tap'),
                subtitle: const Text(
                  'Tapping the terminal presents the soft keyboard',
                ),
                value: controller.keyboardOnTap,
                onChanged: (value) =>
                    unawaited(controller.setKeyboardOnTap(value)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const SectionLabel('Connection'),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.computer, size: 20),
            title: const Text('This device name'),
            subtitle: Text(
              '${controller.clientName}\n'
              'New pairings use ${controller.clientLabel}',
            ),
            trailing: IconButton(
              tooltip: 'Edit device name',
              onPressed: () => unawaited(_editClientName(context)),
              icon: const Icon(Icons.edit_outlined),
            ),
            onTap: () => unawaited(_editClientName(context)),
          ),
        ),
        const SizedBox(height: 10),
        Semantics(
          label:
              'Connection status: '
              '${selected == null ? controller.status : sessionState.message}',
          child: Card(
            child: ListTile(
              leading: Icon(
                selected == null
                    ? Icons.info_outline
                    : sessionState.isAttached
                    ? Icons.link
                    : Icons.link_off,
              ),
              title: Text(
                selected == null ? controller.status : sessionState.message,
              ),
              subtitle: selected == null ? null : Text(selected!.name),
              trailing: openConnectionCount == 0
                  ? null
                  : Text('$openConnectionCount open'),
            ),
          ),
        ),
        if (selected != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onDisconnect,
            icon: const Icon(Icons.link_off),
            label: const Text('Disconnect'),
          ),
        ],
        const SizedBox(height: 8),
      ],
    ),
  );
}

class SavedHostList extends StatefulWidget {
  const SavedHostList({
    super.key,
    required this.hosts,
    required this.selected,
    required this.onConnect,
    required this.onAction,
  });

  final List<SavedHost> hosts;
  final SavedHost? selected;
  final ValueChanged<SavedHost> onConnect;
  final void Function(String action, SavedHost host) onAction;

  @override
  State<SavedHostList> createState() => _SavedHostListState();
}

class _SavedHostListState extends State<SavedHostList> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.addListener(_searchChanged);
  }

  void _searchChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final matches = widget.hosts
        .where((host) => savedHostMatchesQuery(host, _search.text))
        .toList(growable: false);
    return Column(
      children: [
        SizedBox(
          height: 38,
          child: TextField(
            controller: _search,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search hosts',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              prefixIcon: const Icon(Icons.search, size: 18),
              prefixIconConstraints: const BoxConstraints(minWidth: 36),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear host search',
                      onPressed: _search.clear,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      icon: const Icon(Icons.close, size: 18),
                    ),
              suffixIconConstraints: const BoxConstraints(minWidth: 36),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Semantics(
          liveRegion: _search.text.isNotEmpty,
          label: _search.text.isEmpty
              ? null
              : matches.isEmpty
              ? 'No matching hosts'
              : '${matches.length} matching ${matches.length == 1 ? 'host' : 'hosts'}',
          child: Card(
            margin: EdgeInsets.zero,
            child: matches.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        const Text(
                          'No matching hosts',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        TextButton(
                          onPressed: _search.clear,
                          child: const Text('Clear search'),
                        ),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      for (var index = 0; index < matches.length; index++) ...[
                        _SavedHostTile(
                          host: matches[index],
                          selected:
                              matches[index].nodeId == widget.selected?.nodeId,
                          onTap: () => widget.onConnect(matches[index]),
                          onAction: (action) =>
                              widget.onAction(action, matches[index]),
                        ),
                        if (index != matches.length - 1)
                          const Divider(height: 1, indent: 38),
                      ],
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _search.removeListener(_searchChanged);
    _search.dispose();
    super.dispose();
  }
}

class _SavedHostTile extends StatelessWidget {
  const _SavedHostTile({
    required this.host,
    required this.selected,
    required this.onTap,
    required this.onAction,
  });

  final SavedHost host;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final metrics = ZukoMetrics.of(context);
    final showLabel =
        host.name.trim().toLowerCase() != host.label.trim().toLowerCase();
    // The selected host gets a Material 3 tint; the rounded shape keeps the
    // same look the GNOME-style sidebar had.
    return ListTile(
      selected: selected,
      selectedTileColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(metrics.size(6)),
      ),
      title: Text(host.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: showLabel
          ? Text(host.label, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      leading: Icon(Icons.computer, size: metrics.size(18)),
      contentPadding: EdgeInsetsDirectional.only(start: metrics.size(10)),
      onTap: onTap,
      trailing: PopupMenuButton<String>(
        tooltip: 'Manage ${host.name}',
        padding: EdgeInsets.zero,
        iconSize: metrics.size(18),
        icon: const Icon(Icons.more_vert),
        onSelected: onAction,
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'details', child: Text('Details')),
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'forget', child: Text('Forget')),
        ],
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        letterSpacing: 0.4,
      ),
    ),
  );
}

/// A GNOME-style option selector: a [ListTile] row showing the current
/// value with a trailing arrow that opens a checked menu of alternatives.
class OptionTile<T> extends StatelessWidget {
  const OptionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.valueLabel,
    required this.items,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final T value;
  final String Function(T value) valueLabel;
  final List<({T value, String label})> items;
  final ValueChanged<T> onSelected;

  Future<void> _open(BuildContext context) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final tile = context.findRenderObject()! as RenderBox;
    final selected = await showMenu<T>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          tile.localToGlobal(Offset.zero, ancestor: overlay),
          tile.localToGlobal(
            tile.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final item in items)
          PopupMenuItem(
            value: item.value,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: item.value == value
                      ? const Icon(Icons.check, size: 18)
                      : null,
                ),
                Text(item.label),
              ],
            ),
          ),
      ],
    );
    if (selected != null) onSelected(selected);
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, size: 20),
    title: Text(label),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          valueLabel(value),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right, size: 16),
      ],
    ),
    onTap: () => unawaited(_open(context)),
  );
}

// Search matches name, label, node id, and ticket fields.
bool savedHostMatchesQuery(SavedHost host, String query) {
  final terms = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty);
  final searchable = '${host.name}\n${host.label}\n${host.nodeId}'
      .toLowerCase();
  return terms.every(searchable.contains);
}
