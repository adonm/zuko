import 'dart:async';
import 'dart:math' as math;

import 'package:flterm/flterm.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart' hide Key;
import 'package:flutter/services.dart';
import 'package:libghostty/libghostty.dart' show pasteIsSafe;
import 'package:url_launcher/url_launcher.dart';
import 'package:yaru/yaru.dart';

import 'app_controller.dart';
import 'client_name.dart';
import 'model.dart';
import 'pairing_screen.dart';
import 'session_state.dart';
import 'terminal_connection.dart';
import 'theme.dart';
import 'transport.dart';
import 'window_frame.dart';

const _installCommand =
    "curl --proto '=https' --tlsv1.2 -LsSf "
    'https://zuko.adonm.dev/install.sh | sh';
const _shareCommand = 'zuko install\nzuko share';
const terminalAccessoryHeight = kYaruButtonHeight;
const terminalAccessoryItemWidth = kYaruButtonHeight;
const terminalAccessoryGroupSpacing = 6.0;
const terminalNavigationKeys = <({String label, Key key})>[
  (label: 'Home', key: Key.home),
  (label: 'End', key: Key.end),
  (label: 'Page Up', key: Key.pageUp),
  (label: 'Page Down', key: Key.pageDown),
  (label: 'Insert', key: Key.insert),
  (label: 'Delete', key: Key.delete),
];
const terminalFunctionKeys = <({String label, Key key})>[
  (label: 'F1', key: Key.f1),
  (label: 'F2', key: Key.f2),
  (label: 'F3', key: Key.f3),
  (label: 'F4', key: Key.f4),
  (label: 'F5', key: Key.f5),
  (label: 'F6', key: Key.f6),
  (label: 'F7', key: Key.f7),
  (label: 'F8', key: Key.f8),
  (label: 'F9', key: Key.f9),
  (label: 'F10', key: Key.f10),
  (label: 'F11', key: Key.f11),
  (label: 'F12', key: Key.f12),
];
const terminalArrowKeys = <({String label, Key key})>[
  (label: 'Up', key: Key.arrowUp),
  (label: 'Down', key: Key.arrowDown),
  (label: 'Left', key: Key.arrowLeft),
  (label: 'Right', key: Key.arrowRight),
];

IconData _terminalArrowIcon(Key key) => switch (key) {
  Key.arrowUp => YaruFreedesktopIcons.go_up.icon,
  Key.arrowDown => YaruFreedesktopIcons.go_down.icon,
  Key.arrowLeft => YaruFreedesktopIcons.go_previous.icon,
  Key.arrowRight => YaruFreedesktopIcons.go_next.icon,
  _ => throw ArgumentError.value(key, 'key', 'not an arrow key'),
};

bool showConnectionTabs(int connectionCount) => connectionCount > 1;

TerminalGestureSettings terminalGestureSettings({
  required bool touchSelectionEnabled,
}) => TerminalGestureSettings(longPressSelection: touchSelectionEnabled);

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

Future<String?> showDeviceNameDialog(
  BuildContext context, {
  required String initialName,
}) => showDialog<String>(
  context: context,
  builder: (context) => _DeviceNameDialog(initialName: initialName),
);

class _DeviceNameDialog extends StatefulWidget {
  const _DeviceNameDialog({required this.initialName});

  final String initialName;

  @override
  State<_DeviceNameDialog> createState() => _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<_DeviceNameDialog> {
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

class RepeatableAction extends StatefulWidget {
  const RepeatableAction({
    super.key,
    required this.onInvoke,
    required this.child,
    this.initialDelay = const Duration(milliseconds: 400),
    this.repeatInterval = const Duration(milliseconds: 80),
    this.borderRadius,
    this.focusColor,
    this.highlightColor,
    this.hoverColor,
    this.onFocusChange,
  });

  final VoidCallback onInvoke;
  final Widget child;
  final Duration initialDelay;
  final Duration repeatInterval;
  final BorderRadius? borderRadius;
  final Color? focusColor;
  final Color? highlightColor;
  final Color? hoverColor;
  final ValueChanged<bool>? onFocusChange;

  @override
  State<RepeatableAction> createState() => _RepeatableActionState();
}

class _RepeatableActionState extends State<RepeatableAction> {
  Timer? _delayTimer;
  Timer? _repeatTimer;
  int? _activePointer;
  bool _pointerTap = false;

  void _start(PointerDownEvent event) {
    if (_activePointer != null || event.buttons != kPrimaryButton) return;
    _activePointer = event.pointer;
    _pointerTap = true;
    widget.onInvoke();
    _delayTimer = Timer(widget.initialDelay, () {
      if (_activePointer == null) return;
      widget.onInvoke();
      _repeatTimer = Timer.periodic(
        widget.repeatInterval,
        (_) => widget.onInvoke(),
      );
    });
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _activePointer) return;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      _cancel(event);
      return;
    }
    final renderBox = renderObject;
    if (!renderBox.size.contains(event.localPosition)) _cancel();
  }

  void _finish(PointerEvent event) {
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    _stopTimers();
  }

  void _cancel([PointerEvent? event]) {
    if (event != null && event.pointer != _activePointer) return;
    _activePointer = null;
    _pointerTap = false;
    _stopTimers();
  }

  void _stopTimers() {
    _delayTimer?.cancel();
    _repeatTimer?.cancel();
    _delayTimer = null;
    _repeatTimer = null;
  }

  void _tap() {
    if (!_pointerTap) widget.onInvoke();
    _pointerTap = false;
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onExit: _cancel,
    child: Listener(
      onPointerDown: _start,
      onPointerMove: _move,
      onPointerUp: _finish,
      onPointerCancel: _cancel,
      child: InkResponse(
        onTap: _tap,
        onTapCancel: _cancel,
        borderRadius: widget.borderRadius,
        containedInkWell: true,
        focusColor: widget.focusColor,
        highlightColor: widget.highlightColor,
        hoverColor: widget.hoverColor,
        onFocusChange: widget.onFocusChange,
        child: widget.child,
      ),
    ),
  );

  @override
  void dispose() {
    _stopTimers();
    super.dispose();
  }
}

double effectiveTerminalFontSize({
  required double width,
  required double configuredSize,
  required bool customized,
}) {
  if (customized) return configuredSize;
  return width < wideLayoutBreakpoint ? 7 : 10;
}

Uri? supportedTerminalLink(Uri? uri) {
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  return switch (uri.scheme.toLowerCase()) {
    'http' || 'https' => uri,
    _ => null,
  };
}

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
      builder: (context, child) => ZukoWindowFrame(child: child),
    ),
  );
}

class _Home extends StatefulWidget {
  const _Home({required this.controller});
  final AppController controller;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final List<TerminalConnection> _connections = [];
  TabController? _tabController;
  int _activeIndex = -1;
  DateTime? _backgroundedAt;
  bool _sidebarExpanded = true;

  TerminalConnection? get _activeConnection =>
      _activeIndex >= 0 && _activeIndex < _connections.length
      ? _connections[_activeIndex]
      : null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    if (backgroundedAt != null &&
        DateTime.now().difference(backgroundedAt) >=
            const Duration(seconds: 5)) {
      for (final connection in List.of(_connections)) {
        unawaited(connection.reconnect());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController?.dispose();
    final connections = List.of(_connections);
    _connections.clear();
    for (final connection in connections) {
      connection.removeListener(_connectionChanged);
    }
    unawaited(() async {
      try {
        await Future.wait(
          connections.map((connection) async {
            try {
              await connection.close();
            } finally {
              connection.dispose();
            }
          }),
        );
      } finally {
        await widget.controller.close();
      }
    }());
    super.dispose();
  }

  void _replaceTabController() {
    final previous = _tabController;
    _tabController = _connections.isEmpty
        ? null
        : TabController(
            length: _connections.length,
            initialIndex: _activeIndex,
            vsync: this,
          );
    previous?.dispose();
  }

  void _connectionChanged() {
    if (mounted) setState(() {});
  }

  void _focusActiveTerminal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _activeConnection?.terminal.requestFocus();
    });
  }

  void _selectConnection(TerminalConnection connection) {
    final index = _connections.indexOf(connection);
    if (index < 0 || index == _activeIndex) {
      _focusActiveTerminal();
      return;
    }
    setState(() {
      _activeIndex = index;
      _tabController?.index = index;
    });
    _focusActiveTerminal();
  }

  void _selectConnectionAt(int index) {
    if (index < 0 || index >= _connections.length) return;
    _selectConnection(_connections[index]);
  }

  void _openConnection(SavedHost host) {
    final existing = _connections
        .where((connection) => connection.host.nodeId == host.nodeId)
        .firstOrNull;
    if (existing != null) {
      _selectConnection(existing);
      unawaited(existing.updateHost(host));
      return;
    }

    late final TerminalConnection connection;
    connection = TerminalConnection(
      host: host,
      connector: widget.controller.transport.connect,
      onTunnel: _openTunnel,
    );
    connection.addListener(_connectionChanged);
    setState(() {
      _connections.add(connection);
      _activeIndex = _connections.length - 1;
      _replaceTabController();
    });
    unawaited(connection.reconnect());
    _focusActiveTerminal();
  }

  Future<void> _closeConnection(TerminalConnection connection) =>
      _closeConnections([connection]);

  Future<void> _closeConnections(
    Iterable<TerminalConnection> connections,
  ) async {
    final closing = connections
        .where(_connections.contains)
        .toList(growable: false);
    if (closing.isEmpty) return;
    final activeBefore = _activeConnection;
    final firstIndex = _connections.indexOf(closing.first);
    for (final connection in closing) {
      connection.removeListener(_connectionChanged);
    }
    setState(() {
      _connections.removeWhere(closing.contains);
      if (_connections.isEmpty) {
        _activeIndex = -1;
      } else if (activeBefore != null && _connections.contains(activeBefore)) {
        _activeIndex = _connections.indexOf(activeBefore);
      } else {
        _activeIndex = firstIndex.clamp(0, _connections.length - 1);
      }
      _replaceTabController();
    });
    await Future.wait(
      closing.map((connection) async {
        try {
          await connection.close();
        } finally {
          connection.dispose();
        }
      }),
    );
    _focusActiveTerminal();
  }

  Future<void> _openTunnel(
    TerminalConnection connection,
    TunnelEndpoint tunnel,
    int generation,
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
        !_connections.contains(connection) ||
        !connection.isCurrentGeneration(generation)) {
      return;
    }
    final local = '127.0.0.1:${tunnel.localPort}';
    final message = opened
        ? '${connection.host.name}: $local → host 127.0.0.1:${tunnel.hostPort}'
        : '${connection.host.name}: tunnel ready at $local; browser could not be opened.';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openTerminalLink(ActivatedLink link) async {
    final uri = supportedTerminalLink(link.uri);
    if (uri == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Blocked unsupported terminal link')),
        );
      return;
    }

    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!mounted || opened) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Could not open terminal link')),
      );
  }

  Future<void> _pair({bool manual = false}) async {
    final host = await Navigator.of(context).push<SavedHost>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => PairingScreen(
          startInManual: manual,
          onClaim: widget.controller.claim,
        ),
      ),
    );
    if (host != null && mounted) _openConnection(host);
  }

  Future<void> _forget(SavedHost host) async {
    final matching = _connections
        .where((connection) => connection.host.nodeId == host.nodeId)
        .toList(growable: false);
    try {
      await _closeConnections(matching);
    } finally {
      await widget.controller.remove(host);
    }
  }

  void _toggleSidebar() {
    setState(() => _sidebarExpanded = !_sidebarExpanded);
  }

  String _connectionName(TerminalConnection connection) =>
      widget.controller.hosts
          .where((host) => host.nodeId == connection.host.nodeId)
          .map((host) => host.name)
          .firstOrNull ??
      connection.host.name;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final width = MediaQuery.sizeOf(context).width;
      final wide = width >= wideLayoutBreakpoint;
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
      final hasSavedHosts = widget.controller.hosts.isNotEmpty;
      final active = _activeConnection;
      final selected = active?.host;
      final sessionState =
          active?.state ??
          const SessionState.ended('Choose a saved host to open a terminal.');
      final sidebar = _Sidebar(
        controller: widget.controller,
        terminalFontSize: terminalFontSize,
        selected: selected,
        sessionState: sessionState,
        openConnectionCount: _connections.length,
        onPair: () => _pair(),
        onConnect: _openConnection,
        onDisconnect: active == null
            ? () {}
            : () => unawaited(_closeConnection(active)),
        onForget: _forget,
      );
      final terminalTheme = buildZukoTerminalTheme(
        brightness: Theme.of(context).brightness,
        fontSize: terminalFontSize,
      );
      return Scaffold(
        appBar: integratedDesktopHeader
            ? null
            : AppBar(title: const ZukoAppTitle()),
        drawer: wide ? null : Drawer(child: SafeArea(child: sidebar)),
        body: Row(
          children: [
            if (wide)
              _DesktopSidebar(
                expanded: _sidebarExpanded,
                onToggle: _toggleSidebar,
                onPair: () => _pair(),
                showPairAction: hasSavedHosts,
                child: sidebar,
              ),
            if (wide) const VerticalDivider(width: 1),
            Expanded(
              child: active == null
                  ? hasSavedHosts
                        ? _NoOpenConnections(onPair: () => _pair())
                        : _Welcome(
                            onScan: supportsQrScanning() ? () => _pair() : null,
                            onEnterCode: () => _pair(manual: true),
                          )
                  : Column(
                      children: [
                        if (showConnectionTabs(_connections.length)) ...[
                          ConnectionTabStrip(
                            controller: _tabController!,
                            selectedIndex: _activeIndex,
                            connections: _connections,
                            labelFor: _connectionName,
                            onSelected: _selectConnectionAt,
                            onClose: (connection) =>
                                unawaited(_closeConnection(connection)),
                          ),
                          const Divider(height: 1),
                        ],
                        Expanded(
                          child: IndexedStack(
                            index: _activeIndex,
                            children: [
                              for (final connection in _connections)
                                Stack(
                                  key: ObjectKey(connection),
                                  fit: StackFit.expand,
                                  children: [
                                    TerminalView(
                                      controller: connection.terminal,
                                      autofocus: identical(connection, active),
                                      theme: terminalTheme,
                                      gestureSettings: terminalGestureSettings(
                                        touchSelectionEnabled:
                                            connection.touchSelectionEnabled,
                                      ),
                                      semanticsLabel:
                                          '${_connectionName(connection)} remote terminal',
                                      semanticsHint:
                                          'Activate to focus remote terminal input',
                                      linkSettings: LinkSettings(
                                        types: const {
                                          LinkType.osc8,
                                          LinkType.text,
                                        },
                                        onActivate: (link) =>
                                            unawaited(_openTerminalLink(link)),
                                      ),
                                    ),
                                    if (!connection.state.isAttached)
                                      _SessionOverlay(
                                        state: connection.state,
                                        hasHost: true,
                                        onReconnect: connection.reconnect,
                                        onPair: () => _pair(),
                                        onDisconnect: () => unawaited(
                                          _closeConnection(connection),
                                        ),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                        _TerminalAccessory(
                          controller: active.terminal,
                          showAdditionalKeys:
                              widget.controller.showAdditionalKeys,
                          touchSelectionEnabled: active.touchSelectionEnabled,
                          onTouchSelectionChanged:
                              active.setTouchSelectionEnabled,
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

class ConnectionTabStrip extends StatefulWidget {
  const ConnectionTabStrip({
    super.key,
    required this.controller,
    required this.selectedIndex,
    required this.connections,
    required this.labelFor,
    required this.onSelected,
    required this.onClose,
  });

  final TabController controller;
  final int selectedIndex;
  final List<TerminalConnection> connections;
  final String Function(TerminalConnection connection) labelFor;
  final ValueChanged<int> onSelected;
  final ValueChanged<TerminalConnection> onClose;

  @override
  State<ConnectionTabStrip> createState() => _ConnectionTabStripState();
}

class _ConnectionTabStripState extends State<ConnectionTabStrip> {
  static const _minimumTabWidth = 128.0;
  final _scrollController = ScrollController();

  @override
  void didUpdateWidget(ConnectionTabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.selectedIndex != widget.selectedIndex ||
        oldWidget.connections.length != widget.connections.length) {
      _revealSelectedTab();
    }
  }

  void _revealSelectedTab([int? selectedIndex]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (!position.hasContentDimensions || widget.connections.isEmpty) return;
      final contentWidth = math.max(
        position.viewportDimension,
        widget.connections.length * _minimumTabWidth,
      );
      final tabWidth = contentWidth / widget.connections.length;
      final start = (selectedIndex ?? widget.selectedIndex) * tabWidth;
      final end = start + tabWidth;
      final visibleStart = position.pixels;
      final visibleEnd = visibleStart + position.viewportDimension;
      final target = start < visibleStart
          ? start
          : end > visibleEnd
          ? end - position.viewportDimension
          : null;
      if (target != null) {
        unawaited(
          _scrollController.animateTo(
            target.clamp(position.minScrollExtent, position.maxScrollExtent),
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          ),
        );
      }
    });
  }

  void _selected(int index) {
    widget.onSelected(index);
    _revealSelectedTab(index);
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(
          constraints.maxWidth,
          widget.connections.length * _minimumTabWidth,
        );
        return YaruScrollViewUndershoot(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: YaruTabBar(
                tabController: widget.controller,
                onTap: _selected,
                height: 42,
                tabs: [
                  for (final connection in widget.connections)
                    Tab(
                      key: ObjectKey(connection),
                      height: 32,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            connection.state.isAttached
                                ? Icons.link
                                : Icons.link_off,
                            size: 14,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              widget.labelFor(connection),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 2),
                          IconButton(
                            tooltip: 'Close ${widget.labelFor(connection)}',
                            onPressed: () => widget.onClose(connection),
                            icon: const Icon(YaruIcons.window_close, size: 14),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 28,
                              height: 28,
                            ),
                            style: IconButton.styleFrom(
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
}

class _NoOpenConnections extends StatelessWidget {
  const _NoOpenConnections({required this.onPair});

  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            YaruIcons.terminal,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            'No open connections',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          const Text(
            'Choose a saved host to open a terminal. Open hosts stay connected in separate tabs.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onPair,
            icon: const Icon(Icons.add_link),
            label: const Text('Pair another host'),
          ),
        ],
      ),
    ),
  );
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({
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
                  if (showPairAction) ...[
                    const SizedBox(height: 6),
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
    required this.touchSelectionEnabled,
    required this.onTouchSelectionChanged,
  });
  final TerminalController controller;
  final bool showAdditionalKeys;
  final bool touchSelectionEnabled;
  final ValueChanged<bool> onTouchSelectionChanged;

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
        color: colors.surfaceContainerLow,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: terminalAccessoryHeight,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                children: [
                  _AccessoryKey(
                    width: terminalAccessoryItemWidth,
                    label: 'Esc',
                    onPressed: () => controller.sendKey(Key.escape),
                  ),
                  _AccessoryKey(
                    width: terminalAccessoryItemWidth,
                    label: 'Tab',
                    onPressed: () => controller.sendKey(Key.tab),
                  ),
                  const SizedBox(width: terminalAccessoryGroupSpacing),
                  if (showAdditionalKeys) ...[
                    _AccessoryKey(
                      width: terminalAccessoryItemWidth,
                      label: 'Ctrl',
                      selected: controller.virtualMods.hasCtrl,
                      onPressed: () => controller.toggleMod(const Mods.ctrl()),
                    ),
                    _AccessoryKey(
                      width: terminalAccessoryItemWidth,
                      label: 'Alt',
                      selected: controller.virtualMods.hasAlt,
                      onPressed: () => controller.toggleMod(const Mods.alt()),
                    ),
                    const SizedBox(width: terminalAccessoryGroupSpacing),
                    for (final item in terminalArrowKeys)
                      _RepeatableAccessoryIcon(
                        width: terminalAccessoryItemWidth,
                        tooltip: item.label,
                        icon: _terminalArrowIcon(item.key),
                        onPressed: () => controller.sendKey(item.key),
                      ),
                    const SizedBox(width: terminalAccessoryGroupSpacing),
                  ],
                  _AccessoryIcon(
                    width: terminalAccessoryItemWidth,
                    tooltip: controller.keyboardState == KeyboardState.showing
                        ? 'Hide keyboard'
                        : 'Show keyboard',
                    icon: controller.keyboardState == KeyboardState.showing
                        ? YaruIcons.keyboard_filled
                        : YaruFreedesktopIcons.input_keyboard.icon,
                    selected: controller.keyboardState == KeyboardState.showing,
                    onPressed: () {
                      if (controller.keyboardState == KeyboardState.showing) {
                        controller.disableKeyboard();
                      } else {
                        controller.showKeyboard();
                      }
                    },
                  ),
                  _AccessoryIcon(
                    width: terminalAccessoryItemWidth,
                    tooltip: touchSelectionEnabled
                        ? 'Disable touch text selection'
                        : 'Enable touch text selection',
                    icon: Icons.text_fields,
                    selected: touchSelectionEnabled,
                    onPressed: () =>
                        onTouchSelectionChanged(!touchSelectionEnabled),
                  ),
                  _AccessoryIcon(
                    width: terminalAccessoryItemWidth,
                    tooltip: controller.hasSelection
                        ? 'Copy selected text'
                        : 'Paste',
                    icon: controller.hasSelection
                        ? YaruFreedesktopIcons.edit_copy.icon
                        : YaruFreedesktopIcons.edit_paste.icon,
                    onPressed: controller.hasSelection
                        ? () => _copy(context)
                        : () => _paste(context),
                  ),
                  _AccessoryMenu(
                    width: terminalAccessoryItemWidth,
                    hasSelection: controller.hasSelection,
                    onSelected: (action) {
                      switch (action) {
                        case 'extended-keys':
                          unawaited(
                            showTerminalExtendedKeyPalette(
                              context,
                              onKey: (key) => controller.sendKey(key),
                            ),
                          );
                        case 'select-all':
                          controller.selectAll();
                        case 'copy':
                          unawaited(_copy(context));
                        case 'paste':
                          unawaited(_paste(context));
                      }
                    },
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
    required this.label,
    required this.onPressed,
    this.selected,
  });
  final double width;
  final String label;
  final VoidCallback onPressed;
  final bool? selected;

  @override
  Widget build(BuildContext context) => _AccessoryButton(
    width: width,
    tooltip: label,
    selected: selected,
    onPressed: onPressed,
    child: Text(label),
  );
}

class _AccessoryIcon extends StatelessWidget {
  const _AccessoryIcon({
    required this.width,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected,
  });
  final double width;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool? selected;

  @override
  Widget build(BuildContext context) => _AccessoryButton(
    width: width,
    tooltip: tooltip,
    selected: selected,
    onPressed: onPressed,
    child: Icon(icon),
  );
}

class _RepeatableAccessoryIcon extends StatelessWidget {
  const _RepeatableAccessoryIcon({
    required this.width,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final double width;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => _AccessoryButton(
    width: width,
    tooltip: tooltip,
    onPressed: onPressed,
    repeatable: true,
    child: Icon(icon),
  );
}

class _AccessoryButton extends StatefulWidget {
  const _AccessoryButton({
    required this.width,
    required this.tooltip,
    required this.onPressed,
    required this.child,
    this.selected,
    this.repeatable = false,
  });

  final double width;
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
    final radius = BorderRadius.circular(kYaruButtonRadius);
    final foreground = widget.selected == true
        ? colors.primary
        : colors.onSurface.withValues(alpha: 0.8);
    final hoverColor = colors.onSurfaceVariant.withValues(alpha: 0.08);
    final pressedColor = colors.onSurfaceVariant.withValues(alpha: 0.12);
    final content = SizedBox(
      width: widget.width,
      height: terminalAccessoryHeight,
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
              data: IconThemeData(color: foreground, size: kYaruIconSize),
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
    required this.hasSelection,
    required this.onSelected,
  });

  final double width;
  final bool hasSelection;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: terminalAccessoryHeight,
      child: PopupMenuButton<String>(
        tooltip: 'More terminal actions',
        padding: EdgeInsets.zero,
        iconSize: kYaruIconSize,
        icon: const Icon(YaruIcons.view_more),
        style: ButtonStyle(
          fixedSize: WidgetStatePropertyAll(
            Size(width, terminalAccessoryHeight),
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

class _Sidebar extends StatelessWidget {
  const _Sidebar({
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
        _SectionLabel('Saved hosts (${controller.hosts.length})'),
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
        Card(
          child: ListTile(
            leading: const Icon(YaruIcons.computer, size: 20),
            title: const Text('This device name'),
            subtitle: Text(
              '${controller.clientName}\n'
              'New pairings use ${controller.clientLabel}',
            ),
            isThreeLine: true,
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
              prefixIcon: const Icon(YaruIcons.search, size: 18),
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
                      icon: const Icon(YaruIcons.edit_clear, size: 18),
                    ),
              suffixIconConstraints: const BoxConstraints(minWidth: 36),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Card(
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
    final showLabel =
        host.name.trim().toLowerCase() != host.label.trim().toLowerCase();
    return ListTile(
      selected: selected,
      dense: true,
      minTileHeight: showLabel ? 48 : 40,
      visualDensity: const VisualDensity(horizontal: -2, vertical: -4),
      contentPadding: const EdgeInsetsDirectional.only(start: 10),
      horizontalTitleGap: 8,
      leading: Icon(
        selected ? YaruIcons.computer_filled : YaruIcons.computer,
        size: 18,
      ),
      title: Text(host.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: showLabel
          ? Text(host.label, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      onTap: onTap,
      trailing: PopupMenuButton<String>(
        tooltip: 'Manage ${host.name}',
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: const Icon(YaruIcons.view_more),
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

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onScan, required this.onEnterCode});

  final VoidCallback? onScan;
  final VoidCallback onEnterCode;

  Future<void> _copy(BuildContext context, String value) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Copied command')));
    } on PlatformException {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Clipboard access was denied')),
        );
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          children: [
            Image.asset('assets/zuko-logo.png', width: 64, height: 64),
            const SizedBox(height: 16),
            Text(
              'Connect to your host',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Set up Zuko on the computer you want to reach, then pair it once.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            _WelcomeStep(
              number: 1,
              title: 'Install Zuko on the host',
              command: _installCommand,
              onCopy: (value) => _copy(context, value),
            ),
            const SizedBox(height: 12),
            _WelcomeStep(
              number: 2,
              title: 'Start it and create a one-time share code',
              command: _shareCommand,
              onCopy: (value) => _copy(context, value),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (onScan != null)
                  FilledButton.icon(
                    onPressed: onScan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QR code'),
                  )
                else
                  FilledButton.icon(
                    onPressed: onEnterCode,
                    icon: const Icon(Icons.keyboard_outlined),
                    label: const Text('Enter pairing code'),
                  ),
                if (onScan != null)
                  OutlinedButton.icon(
                    onPressed: onEnterCode,
                    icon: const Icon(Icons.keyboard_outlined),
                    label: const Text('Enter code instead'),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep({
    required this.number,
    required this.title,
    required this.command,
    required this.onCopy,
  });

  final int number;
  final String title;
  final String command;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
            child: Text('$number'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                _Command(command: command, onCopy: onCopy),
              ],
            ),
          ),
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
        icon: Icon(YaruFreedesktopIcons.edit_copy.icon, size: 18),
      ),
    ],
  );
}
