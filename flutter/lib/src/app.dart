import 'dart:async';

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart' hide Key;
import 'package:flutter/services.dart';
import 'package:libghostty/libghostty.dart' show pasteIsSafe;

import 'app_controller.dart';
import 'model.dart';
import 'session_state.dart';
import 'transport.dart';
import 'wire.dart';

const _background = Color(0xff080b10);
const _orange = Color(0xffef7d3c);
const _mint = Color(0xff75c7b7);
const _installCommand =
    "curl --proto '=https' --tlsv1.2 -LsSf "
    'https://zuko.adonm.dev/install.sh | sh';
const _shareCommand = 'zuko install\nzuko share';

class ZukoApp extends StatelessWidget {
  const ZukoApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => MaterialApp(
      title: 'zuko',
      debugShowCheckedModeBanner: false,
      themeMode: switch (controller.theme) {
        AppThemePreference.system => ThemeMode.system,
        AppThemePreference.dark => ThemeMode.dark,
        AppThemePreference.light => ThemeMode.light,
      },
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: _Home(controller: controller),
    ),
  );
}

ThemeData _theme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return ThemeData(
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _orange,
      brightness: brightness,
    ),
    scaffoldBackgroundColor: dark ? _background : const Color(0xfff4f1ed),
    useMaterial3: true,
  );
}

class _Home extends StatefulWidget {
  const _Home({required this.controller});
  final AppController controller;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> with WidgetsBindingObserver {
  late final TerminalController terminal;
  TerminalSession? session;
  StreamSubscription<Uint8List>? outputSubscription;
  StreamSubscription<SessionState>? stateSubscription;
  SavedHost? selected;
  SessionState sessionState = const SessionState.ended(
    'Choose a saved host or pair a new one.',
  );
  TerminalGeometry geometry = const TerminalGeometry(80, 24, 0, 0);
  DateTime? _backgroundedAt;
  int _sessionGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    terminal = TerminalController();
    terminal.onOutput = (bytes) => unawaited(session?.send(bytes));
    terminal.onResize = (cols, rows) {
      geometry = TerminalGeometry(cols, rows, 0, 0);
      unawaited(session?.resize(geometry));
    };
    terminal.write(
      Uint8List.fromList(
        '\x1b[1;38;2;239;125;60mzuko\x1b[0m ready\r\n'.codeUnits,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    final host = selected;
    if (host != null &&
        backgroundedAt != null &&
        DateTime.now().difference(backgroundedAt) >=
            const Duration(seconds: 5)) {
      unawaited(_connect(host));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionGeneration++;
    final active = session;
    final output = outputSubscription;
    final states = stateSubscription;
    session = null;
    outputSubscription = null;
    stateSubscription = null;
    unawaited(() async {
      await output?.cancel();
      await states?.cancel();
      await active?.close();
      await widget.controller.close();
    }());
    terminal.dispose();
    super.dispose();
  }

  Future<void> _connect(SavedHost host) async {
    final generation = ++_sessionGeneration;
    final previous = session;
    final previousOutput = outputSubscription;
    final previousStates = stateSubscription;
    session = null;
    outputSubscription = null;
    stateSubscription = null;
    selected = host;
    sessionState = const SessionState.connecting();
    if (mounted) setState(() {});

    await previousOutput?.cancel();
    await previousStates?.cancel();
    await previous?.close();
    if (!mounted || generation != _sessionGeneration) return;

    try {
      final active = widget.controller.transport.connect(host, geometry);
      if (!mounted || generation != _sessionGeneration) {
        await active.close();
        return;
      }
      session = active;
      outputSubscription = active.output.listen((bytes) {
        if (mounted &&
            generation == _sessionGeneration &&
            identical(session, active)) {
          terminal.write(bytes);
        }
      });
      stateSubscription = active.states.listen((state) {
        if (!mounted ||
            generation != _sessionGeneration ||
            !identical(session, active)) {
          return;
        }
        setState(() => sessionState = state);
      });
      setState(() {});
      terminal.requestFocus();
    } catch (error) {
      if (!mounted || generation != _sessionGeneration) return;
      setState(() {
        sessionState = SessionState.failed('Could not start session: $error');
      });
    }
  }

  Future<void> _disconnect() async {
    ++_sessionGeneration;
    final active = session;
    final output = outputSubscription;
    final states = stateSubscription;
    session = null;
    outputSubscription = null;
    stateSubscription = null;
    selected = null;
    sessionState = const SessionState.ended(
      'Choose a saved host or pair a new one.',
    );
    if (mounted) setState(() {});
    await output?.cancel();
    await states?.cancel();
    await active?.close();
  }

  Future<void> _pair() async {
    final code = TextEditingController();
    final name = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pair a host'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: code,
              autofocus: true,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Share code'),
            ),
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Save as'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Pair'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      try {
        final host = await widget.controller.claim(code.text, name.text);
        if (mounted) await _connect(host);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(widget.controller.status)));
        }
      }
    }
    code.dispose();
    name.dispose();
  }

  Future<void> _forget(SavedHost host) async {
    if (selected?.nodeId == host.nodeId) await _disconnect();
    await widget.controller.remove(host);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final wide = MediaQuery.sizeOf(context).width >= 760;
      final sidebar = _Sidebar(
        controller: widget.controller,
        selected: selected,
        sessionState: sessionState,
        onPair: _pair,
        onConnect: _connect,
        onDisconnect: _disconnect,
        onForget: _forget,
      );
      final terminalTheme =
          (Theme.of(context).brightness == Brightness.dark
                  ? TerminalTheme.dark()
                  : TerminalTheme.light())
              .copyWith(
                fontFamily: 'JetBrains Mono',
                fontFamilyFallback: const [
                  'Noto Sans Mono',
                  'Noto Emoji',
                  'Noto Sans Symbols 2',
                ],
                fontSize: widget.controller.terminalFontSize,
              );
      final selectedHost = selected;
      return Scaffold(
        appBar: AppBar(
          leading: Padding(
            padding: const EdgeInsets.all(10),
            child: Image.asset('assets/zuko-logo.png'),
          ),
          title: const Text('zuko'),
          foregroundColor: _orange,
        ),
        drawer: wide ? null : Drawer(child: SafeArea(child: sidebar)),
        body: Row(
          children: [
            if (wide) SizedBox(width: 300, child: sidebar),
            if (wide) const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Semantics(
                          label: 'Remote terminal',
                          child: TerminalView(
                            controller: terminal,
                            autofocus: true,
                            theme: terminalTheme,
                          ),
                        ),
                        if (!sessionState.isAttached)
                          _SessionOverlay(
                            state: sessionState,
                            hasHost: selected != null,
                            onReconnect: selectedHost == null
                                ? null
                                : () => _connect(selectedHost),
                            onPair: _pair,
                            onDisconnect: selected == null ? null : _disconnect,
                          ),
                      ],
                    ),
                  ),
                  _TerminalAccessory(
                    controller: terminal,
                    showAdditionalKeys: widget.controller.showAdditionalKeys,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _SessionOverlay extends StatelessWidget {
  const _SessionOverlay({
    required this.state,
    required this.hasHost,
    required this.onReconnect,
    required this.onPair,
    required this.onDisconnect,
  });

  final SessionState state;
  final bool hasHost;
  final VoidCallback? onReconnect;
  final VoidCallback onPair;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black.withValues(alpha: 0.58),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state.phase == SessionPhase.connecting ||
                    state.phase == SessionPhase.retrying)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: CircularProgressIndicator(),
                  ),
                Text(
                  state.message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (state.recovery == SessionRecovery.reconnect &&
                        onReconnect != null)
                      FilledButton.icon(
                        onPressed: onReconnect,
                        icon: const Icon(Icons.refresh),
                        label: Text(
                          state.phase == SessionPhase.retrying
                              ? 'Retry now'
                              : 'Reconnect',
                        ),
                      ),
                    if (state.recovery == SessionRecovery.rePair || !hasHost)
                      FilledButton.icon(
                        onPressed: onPair,
                        icon: const Icon(Icons.add_link),
                        label: Text(hasHost ? 'Pair again' : 'Pair host'),
                      ),
                    if (onDisconnect != null)
                      OutlinedButton.icon(
                        onPressed: onDisconnect,
                        icon: const Icon(Icons.link_off),
                        label: const Text('Disconnect'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _TerminalAccessory extends StatelessWidget {
  const _TerminalAccessory({
    required this.controller,
    required this.showAdditionalKeys,
  });
  final TerminalController controller;
  final bool showAdditionalKeys;

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
      controller.requestFocus();
    } on PlatformException {
      if (!context.mounted) return;
      _showClipboardMessage(context, 'Clipboard access was denied');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            children: [
              _AccessoryKey(
                label: 'Esc',
                onPressed: () => controller.sendKey(Key.escape),
              ),
              _AccessoryKey(
                label: 'Tab',
                onPressed: () => controller.sendKey(Key.tab),
              ),
              if (showAdditionalKeys) ...[
                _AccessoryKey(
                  label: 'Ctrl',
                  selected: controller.virtualMods.hasCtrl,
                  onPressed: () => controller.toggleMod(const Mods.ctrl()),
                ),
                _AccessoryKey(
                  label: 'Alt',
                  selected: controller.virtualMods.hasAlt,
                  onPressed: () => controller.toggleMod(const Mods.alt()),
                ),
                _AccessoryIcon(
                  tooltip: 'Left',
                  icon: Icons.arrow_left,
                  onPressed: () => controller.sendKey(Key.arrowLeft),
                ),
                _AccessoryIcon(
                  tooltip: 'Up',
                  icon: Icons.arrow_drop_up,
                  onPressed: () => controller.sendKey(Key.arrowUp),
                ),
                _AccessoryIcon(
                  tooltip: 'Down',
                  icon: Icons.arrow_drop_down,
                  onPressed: () => controller.sendKey(Key.arrowDown),
                ),
                _AccessoryIcon(
                  tooltip: 'Right',
                  icon: Icons.arrow_right,
                  onPressed: () => controller.sendKey(Key.arrowRight),
                ),
              ],
              _AccessoryIcon(
                tooltip: controller.keyboardState == KeyboardState.showing
                    ? 'Hide keyboard'
                    : 'Show keyboard',
                icon: controller.keyboardState == KeyboardState.showing
                    ? Icons.keyboard_hide
                    : Icons.keyboard,
                onPressed: () {
                  if (controller.keyboardState == KeyboardState.showing) {
                    controller.disableKeyboard();
                  } else {
                    controller.showKeyboard();
                  }
                },
              ),
              _AccessoryIcon(
                tooltip: 'Select all terminal text',
                icon: Icons.select_all,
                onPressed: controller.selectAll,
              ),
              _AccessoryIcon(
                tooltip: 'Copy selected text',
                icon: Icons.copy,
                onPressed: controller.hasSelection
                    ? () => _copy(context)
                    : null,
              ),
              _AccessoryIcon(
                tooltip: 'Paste',
                icon: Icons.content_paste,
                onPressed: () => _paste(context),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AccessoryKey extends StatelessWidget {
  const _AccessoryKey({
    required this.label,
    required this.onPressed,
    this.selected = false,
  });
  final String label;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
    child: TextButton(
      style: TextButton.styleFrom(
        backgroundColor: selected
            ? Theme.of(context).colorScheme.primaryContainer
            : null,
        minimumSize: const Size(44, 36),
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      onPressed: onPressed,
      child: Text(label),
    ),
  );
}

class _AccessoryIcon extends StatelessWidget {
  const _AccessoryIcon({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) =>
      IconButton(tooltip: tooltip, onPressed: onPressed, icon: Icon(icon));
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.controller,
    required this.selected,
    required this.sessionState,
    required this.onPair,
    required this.onConnect,
    required this.onDisconnect,
    required this.onForget,
  });

  final AppController controller;
  final SavedHost? selected;
  final SessionState sessionState;
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
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FilledButton.icon(
          onPressed: controller.busy ? null : onPair,
          icon: const Icon(Icons.add_link),
          label: const Text('Pair host'),
        ),
        const SizedBox(height: 20),
        Text(
          'SAVED HOSTS',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: _mint),
        ),
        const SizedBox(height: 8),
        if (controller.hosts.isEmpty)
          _Onboarding(onCopy: (value) => _copy(context, value)),
        for (final host in controller.hosts)
          ListTile(
            selected: host.nodeId == selected?.nodeId,
            contentPadding: EdgeInsets.zero,
            title: Text(host.name),
            subtitle: Text(
              host.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => onConnect(host),
            trailing: PopupMenuButton<String>(
              tooltip: 'Manage ${host.name}',
              onSelected: (action) {
                switch (action) {
                  case 'details':
                    unawaited(_details(context, host));
                  case 'rename':
                    unawaited(_rename(context, host));
                  case 'forget':
                    unawaited(_confirmForget(context, host));
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'details', child: Text('Details')),
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'forget', child: Text('Forget')),
              ],
            ),
          ),
        const Divider(height: 32),
        Text(
          'APPEARANCE',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: _mint),
        ),
        DropdownButton<AppThemePreference>(
          isExpanded: true,
          value: controller.theme,
          onChanged: (value) {
            if (value != null) unawaited(controller.setTheme(value));
          },
          items: const [
            DropdownMenuItem(
              value: AppThemePreference.system,
              child: Text('System theme'),
            ),
            DropdownMenuItem(
              value: AppThemePreference.dark,
              child: Text('Dark theme'),
            ),
            DropdownMenuItem(
              value: AppThemePreference.light,
              child: Text('Light theme'),
            ),
          ],
        ),
        Row(
          children: [
            const Expanded(child: Text('Terminal text')),
            IconButton(
              tooltip: 'Decrease font size',
              onPressed: controller.terminalFontSize <= 10
                  ? null
                  : () => unawaited(
                      controller.setTerminalFontSize(
                        controller.terminalFontSize - 1,
                      ),
                    ),
              icon: const Icon(Icons.remove),
            ),
            Text('${controller.terminalFontSize.round()}'),
            IconButton(
              tooltip: 'Increase font size',
              onPressed: controller.terminalFontSize >= 24
                  ? null
                  : () => unawaited(
                      controller.setTerminalFontSize(
                        controller.terminalFontSize + 1,
                      ),
                    ),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Additional terminal keys'),
          subtitle: const Text('Show modifiers and arrow keys'),
          value: controller.showAdditionalKeys,
          onChanged: (value) =>
              unawaited(controller.setShowAdditionalKeys(value)),
        ),
        const Divider(height: 32),
        Text(
          selected == null ? controller.status : sessionState.message,
          semanticsLabel:
              'Connection status: '
              '${selected == null ? controller.status : sessionState.message}',
        ),
        if (selected != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onDisconnect,
            icon: const Icon(Icons.link_off),
            label: const Text('Disconnect'),
          ),
        ],
      ],
    ),
  );
}

class _Onboarding extends StatelessWidget {
  const _Onboarding({required this.onCopy});
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('1. Install zuko on the host'),
          _Command(command: _installCommand, onCopy: onCopy),
          const SizedBox(height: 8),
          const Text('2. Start it and create a one-time share code'),
          _Command(command: _shareCommand, onCopy: onCopy),
          const SizedBox(height: 8),
          const Text('3. Tap Pair host and enter the two-word code.'),
        ],
      ),
    ),
  );
}

class _Command extends StatelessWidget {
  const _Command({required this.command, required this.onCopy});
  final String command;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Text(
          command,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
      ),
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: 'Copy command',
        onPressed: () => onCopy(command),
        icon: const Icon(Icons.copy, size: 18),
      ),
    ],
  );
}
