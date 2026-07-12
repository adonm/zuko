import 'dart:async';

import 'package:flterm/flterm.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart' hide Key;
import 'package:flutter/services.dart';
import 'package:libghostty/libghostty.dart' show pasteIsSafe;
import 'package:url_launcher/url_launcher.dart';

import 'app_controller.dart';
import 'model.dart';
import 'session_state.dart';
import 'theme.dart';
import 'transport.dart';
import 'wire.dart';

const _installCommand =
    "curl --proto '=https' --tlsv1.2 -LsSf "
    'https://zuko.adonm.dev/install.sh | sh';
const _shareCommand = 'zuko install\nzuko share';
const _wideLayoutBreakpoint = 760.0;

double effectiveTerminalFontSize({
  required double width,
  required double configuredSize,
  required bool customized,
}) => !customized && width < _wideLayoutBreakpoint ? 5 : configuredSize;

bool usesIntegratedDesktopHeader({
  required double width,
  required TargetPlatform platform,
  required bool isWeb,
}) =>
    width >= _wideLayoutBreakpoint &&
    !isWeb &&
    switch (platform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => false,
    };

class ZukoApp extends StatelessWidget {
  const ZukoApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => MaterialApp(
      title: 'Zuko',
      debugShowCheckedModeBanner: false,
      themeMode: switch (controller.theme) {
        AppThemePreference.system => ThemeMode.system,
        AppThemePreference.dark => ThemeMode.dark,
        AppThemePreference.light => ThemeMode.light,
      },
      theme: buildZukoTheme(Brightness.light),
      darkTheme: buildZukoTheme(Brightness.dark),
      home: _Home(controller: controller),
    ),
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
  StreamSubscription<TunnelEndpoint>? tunnelSubscription;
  SavedHost? selected;
  SessionState sessionState = const SessionState.ended(
    'Choose a saved host or pair a new one.',
  );
  TerminalGeometry geometry = const TerminalGeometry(80, 24, 0, 0);
  DateTime? _backgroundedAt;
  int _sessionGeneration = 0;
  bool _sidebarExpanded = true;

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
        '\x1b[1;38;2;197;64;74mzuko\x1b[0m ready\r\n'.codeUnits,
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
    final tunnels = tunnelSubscription;
    session = null;
    outputSubscription = null;
    stateSubscription = null;
    tunnelSubscription = null;
    unawaited(() async {
      await output?.cancel();
      await states?.cancel();
      await tunnels?.cancel();
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
    final previousTunnels = tunnelSubscription;
    session = null;
    outputSubscription = null;
    stateSubscription = null;
    tunnelSubscription = null;
    selected = host;
    sessionState = const SessionState.connecting();
    if (mounted) setState(() {});

    await previousOutput?.cancel();
    await previousStates?.cancel();
    await previousTunnels?.cancel();
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
      tunnelSubscription = active.tunnels.listen((tunnel) {
        if (mounted &&
            generation == _sessionGeneration &&
            identical(session, active)) {
          unawaited(_openTunnel(tunnel, generation, active));
        }
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

  Future<void> _openTunnel(
    TunnelEndpoint tunnel,
    int generation,
    TerminalSession active,
  ) async {
    var opened = false;
    try {
      opened = await launchUrl(
        tunnel.browserUrl,
        mode: LaunchMode.inAppBrowserView,
      );
      if (!opened) {
        opened = await launchUrl(
          tunnel.browserUrl,
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (_) {
      try {
        opened = await launchUrl(
          tunnel.browserUrl,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        opened = false;
      }
    }
    if (!mounted ||
        generation != _sessionGeneration ||
        !identical(session, active)) {
      return;
    }
    final local = '127.0.0.1:${tunnel.localPort}';
    final message = opened
        ? 'Tunnel opened: $local → host 127.0.0.1:${tunnel.hostPort}'
        : 'Tunnel ready at $local (browser could not be opened).';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _disconnect() async {
    ++_sessionGeneration;
    final active = session;
    final output = outputSubscription;
    final states = stateSubscription;
    final tunnels = tunnelSubscription;
    session = null;
    outputSubscription = null;
    stateSubscription = null;
    tunnelSubscription = null;
    selected = null;
    sessionState = const SessionState.ended(
      'Choose a saved host or pair a new one.',
    );
    if (mounted) setState(() {});
    await output?.cancel();
    await states?.cancel();
    await tunnels?.cancel();
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

  void _toggleSidebar() {
    setState(() => _sidebarExpanded = !_sidebarExpanded);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final width = MediaQuery.sizeOf(context).width;
      final wide = width >= _wideLayoutBreakpoint;
      final terminalFontSize = effectiveTerminalFontSize(
        width: width,
        configuredSize: widget.controller.terminalFontSize,
        customized: widget.controller.terminalFontSizeCustomized,
      );
      final integratedDesktopHeader = usesIntegratedDesktopHeader(
        width: width,
        platform: defaultTargetPlatform,
        isWeb: kIsWeb,
      );
      final sidebar = _Sidebar(
        controller: widget.controller,
        terminalFontSize: terminalFontSize,
        selected: selected,
        sessionState: sessionState,
        onPair: _pair,
        onConnect: _connect,
        onDisconnect: _disconnect,
        onForget: _forget,
      );
      final terminalTheme = buildZukoTerminalTheme(
        brightness: Theme.of(context).brightness,
        fontSize: terminalFontSize,
      );
      final selectedHost = selected;
      return Scaffold(
        appBar: integratedDesktopHeader
            ? null
            : AppBar(
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/zuko-logo.png', width: 28, height: 28),
                    const SizedBox(width: 10),
                    const Text('Zuko'),
                  ],
                ),
              ),
        drawer: wide ? null : Drawer(child: SafeArea(child: sidebar)),
        body: Row(
          children: [
            if (wide)
              _DesktopSidebar(
                expanded: _sidebarExpanded,
                onToggle: _toggleSidebar,
                onPair: _pair,
                child: sidebar,
              ),
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

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({
    required this.expanded,
    required this.onToggle,
    required this.onPair,
    required this.child,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onPair;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSize(
    duration: const Duration(milliseconds: 200),
    curve: Curves.easeOutCubic,
    alignment: Alignment.centerLeft,
    child: SizedBox(
      width: expanded ? 300 : 56,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: expanded
            ? Column(
                children: [
                  SizedBox(
                    height: 52,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 16,
                        end: 6,
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
                    height: 52,
                    child: IconButton(
                      onPressed: onToggle,
                      tooltip: 'Expand sidebar',
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ),
                  const Divider(height: 1),
                  const SizedBox(height: 6),
                  IconButton(
                    onPressed: onPair,
                    tooltip: 'Pair a new host',
                    icon: const Icon(Icons.add_link),
                  ),
                ],
              ),
      ),
    ),
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
    color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.62),
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
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      return Material(
        color: colors.surfaceContainerHigh,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
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
    },
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
        foregroundColor: selected
            ? Theme.of(context).colorScheme.onPrimaryContainer
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
    required this.terminalFontSize,
    required this.selected,
    required this.sessionState,
    required this.onPair,
    required this.onConnect,
    required this.onDisconnect,
    required this.onForget,
  });

  final AppController controller;
  final double terminalFontSize;
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
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
    ),
    child: ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const SizedBox(height: 2),
        FilledButton.icon(
          onPressed: controller.busy ? null : onPair,
          icon: const Icon(Icons.add_link),
          label: const Text('Pair host'),
        ),
        const SizedBox(height: 18),
        const _SectionLabel('Saved hosts'),
        const SizedBox(height: 8),
        if (controller.hosts.isEmpty)
          _Onboarding(onCopy: (value) => _copy(context, value)),
        if (controller.hosts.isNotEmpty)
          Card(
            child: Column(
              children: [
                for (
                  var index = 0;
                  index < controller.hosts.length;
                  index++
                ) ...[
                  ListTile(
                    selected:
                        controller.hosts[index].nodeId == selected?.nodeId,
                    leading: const Icon(Icons.computer_outlined),
                    title: Text(controller.hosts[index].name),
                    subtitle: Text(
                      controller.hosts[index].label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => onConnect(controller.hosts[index]),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Manage ${controller.hosts[index].name}',
                      onSelected: (action) {
                        final host = controller.hosts[index];
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
                  if (index != controller.hosts.length - 1)
                    const Divider(indent: 48),
                ],
              ],
            ),
          ),
        const SizedBox(height: 24),
        const _SectionLabel('Appearance'),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    const Icon(Icons.palette_outlined, size: 20),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('Color scheme')),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<AppThemePreference>(
                        value: controller.theme,
                        borderRadius: BorderRadius.circular(9),
                        onChanged: (value) {
                          if (value != null) {
                            unawaited(controller.setTheme(value));
                          }
                        },
                        items: const [
                          DropdownMenuItem(
                            value: AppThemePreference.system,
                            child: Text('System'),
                          ),
                          DropdownMenuItem(
                            value: AppThemePreference.dark,
                            child: Text('Dark'),
                          ),
                          DropdownMenuItem(
                            value: AppThemePreference.light,
                            child: Text('Light'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
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
                      onPressed: terminalFontSize >= 24
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
                title: const Text('Additional terminal keys'),
                subtitle: const Text('Show modifiers and arrows'),
                value: controller.showAdditionalKeys,
                onChanged: (value) =>
                    unawaited(controller.setShowAdditionalKeys(value)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const _SectionLabel('Connection'),
        const SizedBox(height: 8),
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

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
