import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flterm/flterm.dart' hide Scrollbar;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart' hide Key;
import 'package:url_launcher/url_launcher.dart';

import 'accessory_bar.dart';
import 'app_controller.dart';
import 'connection_hub.dart';
import 'floating_terminal_pad.dart';
import 'model.dart';
import 'pairing_screen.dart';
import 'session_state.dart';
import 'terminal_connection.dart';
import 'connection_tab_strip.dart';
import 'repeatable_action.dart';
import 'session_overlay.dart';
import 'sidebar.dart';
import 'terminal_key_lists.dart';
import 'welcome_screen.dart';
import 'theme.dart';
import 'transport.dart';
import 'window_frame.dart';

final class ZukoScrollBehavior extends MaterialScrollBehavior {
  const ZukoScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
  };
}

/// Collapse policy for the terminal accessory row.
class ZukoApp extends StatelessWidget {
  const ZukoApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => MaterialApp(
      title: 'Zuko',
      debugShowCheckedModeBanner: false,
      scrollBehavior: defaultTargetPlatform == TargetPlatform.linux
          ? const ZukoScrollBehavior()
          : const MaterialScrollBehavior(),
      themeMode: switch (controller.theme) {
        AppThemePreference.system => ThemeMode.system,
        AppThemePreference.dark => ThemeMode.dark,
        AppThemePreference.light => ThemeMode.light,
      },
      theme: buildZukoTheme(
        Brightness.light,
        interfaceSize: controller.interfaceSize,
      ),
      darkTheme: buildZukoTheme(
        Brightness.dark,
        interfaceSize: controller.interfaceSize,
      ),
      home: _Home(controller: controller),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(switch (controller.interfaceSize) {
            AppInterfaceSize.compact => 0.95,
            AppInterfaceSize.standard => 1.0,
            AppInterfaceSize.comfortable => 1.1,
          }),
        ),
        child: child ?? const SizedBox.shrink(),
      ),
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
  late final ConnectionHub _hub;
  bool _isForeground = false;
  bool _sidebarExpanded = false;

  TerminalConnection? get _activeConnection => _hub.active;

  // The floating pad's position inside the terminal pane; kept across tab
  // switches. Dragging the pad updates it.
  Offset _padPosition = const Offset(12, 64);

  void _movePad(Offset delta, Size bounds) {
    const padExtent = Size(148, 180);
    setState(() {
      _padPosition = Offset(
        (_padPosition.dx + delta.dx).clamp(
          0,
          (bounds.width - padExtent.width).clamp(0, double.infinity),
        ),
        (_padPosition.dy + delta.dy).clamp(
          0,
          (bounds.height - padExtent.height).clamp(0, double.infinity),
        ),
      );
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isForeground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _hub = ConnectionHub(
      connector: widget.controller.transport.connect,
      onTunnel: _openTunnel,
      isClipboardSourceActive: (connection) =>
          mounted && _isForeground && identical(connection, _hub.active),
    )..addListener(_connectionChanged);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _hub.handleLifecyclePaused();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    _hub.handleLifecycleResumed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hub.removeListener(_connectionChanged);
    unawaited(() async {
      try {
        await _hub.disposeAll();
      } finally {
        await widget.controller.close();
      }
    }());
    super.dispose();
  }

  void _connectionChanged() {
    if (mounted) setState(() {});
  }

  void _focusActiveTerminal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _activeConnection?.focusNode.requestFocus();
    });
  }

  void _selectConnection(TerminalConnection connection) {
    _hub.select(connection);
    _focusActiveTerminal();
  }

  void _selectConnectionAt(int index) {
    if (index < 0 || index >= _hub.connections.length) return;
    _selectConnection(_hub.connections[index]);
  }

  void _openConnection(SavedHost host) {
    final existing = _hub.forHost(host);
    if (existing != null) {
      _selectConnection(existing);
      unawaited(existing.updateHost(host));
      return;
    }
    _hub.open(host);
    _focusActiveTerminal();
  }

  Future<void> _closeConnection(TerminalConnection connection) =>
      _hub.close(connection);

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
        !_hub.connections.contains(connection) ||
        !connection.isCurrentGeneration(generation)) {
      return;
    }
    final local = '127.0.0.1:${tunnel.localPort}';
    final name = connection.host.value.name;
    final message = opened
        ? '$name: $local → host 127.0.0.1:${tunnel.hostPort}'
        : '$name: tunnel ready at $local; browser could not be opened.';
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
    final matching = _hub.connections
        .where((connection) => connection.host.value.nodeId == host.nodeId)
        .toList(growable: false);
    try {
      for (final connection in matching) {
        await _hub.close(connection);
      }
    } finally {
      await widget.controller.remove(host);
    }
  }

  void _toggleSidebar() {
    setState(() => _sidebarExpanded = !_sidebarExpanded);
  }

  String _connectionName(TerminalConnection connection) =>
      widget.controller.hosts
          .where((host) => host.nodeId == connection.host.value.nodeId)
          .map((host) => host.name)
          .firstOrNull ??
      connection.host.value.name;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final width = MediaQuery.sizeOf(context).width;
      final metrics = ZukoMetrics.of(context);
      final wide = width >= metrics.wideLayoutBreakpoint;
      final terminalFontSize = effectiveTerminalFontSize(
        wideLayout: wide,
        configuredSize: widget.controller.terminalFontSize,
        customized: widget.controller.terminalFontSizeCustomized,
      );
      final integratedDesktopHeader = usesIntegratedDesktopHeader(
        wideLayout: wide,
        platform: defaultTargetPlatform,
        isWeb: kIsWeb,
      );
      final hasSavedHosts = widget.controller.hosts.isNotEmpty;
      final active = _activeConnection;
      final selected = active?.host.value;
      final sessionState =
          active?.state.value ??
          const SessionState.ended('Choose a saved host to open a terminal.');
      final sidebar = Sidebar(
        controller: widget.controller,
        terminalFontSize: terminalFontSize,
        selected: selected,
        sessionState: sessionState,
        openConnectionCount: _hub.connections.length,
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
      final touchPlatform = switch (defaultTargetPlatform) {
        TargetPlatform.iOS || TargetPlatform.android => true,
        _ => false,
      };
      // Integration tests opt into the touch shell on desktop so the pad,
      // drawer logo, and top-bar-free layout can be exercised on CI.
      const forceTouchPad = bool.fromEnvironment('ZUKO_FORCE_TOUCH_PAD');
      final touchShell = touchPlatform || forceTouchPad;
      return Scaffold(
        appBar: integratedDesktopHeader || touchShell
            ? null
            : AppBar(title: const ZukoAppTitle()),
        drawer: wide ? null : Drawer(child: SafeArea(child: sidebar)),
        // Landscape Dynamic Island devices need left and right insets for
        // the sidebar and terminal alike; portrait keeps the top inset on
        // touch devices where no app bar covers the status area. Bottom
        // belongs to the accessory's own SafeArea.
        body: SafeArea(
          top: touchShell,
          bottom: false,
          child: Row(
            children: [
              // Wide layouts keep the collapsed rail so the sidebar stays
              // reachable before any terminal opens; the logo button in the
              // accessory (and the pad's logo on touch) expands it.
              if (wide)
                DesktopSidebar(
                  expanded: _sidebarExpanded,
                  onToggle: _toggleSidebar,
                  onPair: () => _pair(),
                  showPairAction: hasSavedHosts,
                  child: sidebar,
                ),
              if (wide) const VerticalDivider(width: 1),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Built with a context below the Scaffold so the narrow
                    // drawer path can resolve Scaffold.of.
                    final toggleSidebar = wide
                        ? _toggleSidebar
                        : () => Scaffold.of(context).openDrawer();
                    final showPad = touchShell && active != null;
                    final paneSize = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: active == null
                              ? hasSavedHosts
                                    ? NoOpenConnections(onPair: () => _pair())
                                    : Welcome(
                                        onScan: supportsQrScanning()
                                            ? () => _pair()
                                            : null,
                                        onEnterCode: () => _pair(manual: true),
                                      )
                              : Column(
                                  children: [
                                    if (showConnectionTabs(
                                      _hub.connections.length,
                                    )) ...[
                                      ConnectionTabStrip(
                                        selectedIndex: _hub.activeIndex,
                                        connections: _hub.connections,
                                        labelFor: _connectionName,
                                        onSelected: _selectConnectionAt,
                                        onClose: (connection) => unawaited(
                                          _closeConnection(connection),
                                        ),
                                      ),
                                      const Divider(height: 1),
                                    ],
                                    Expanded(
                                      child: IndexedStack(
                                        index: _hub.activeIndex,
                                        children: [
                                          for (final connection
                                              in _hub.connections)
                                            Stack(
                                              key: ObjectKey(connection),
                                              fit: StackFit.expand,
                                              children: [
                                                // Upstream flterm 0.0.5 has no terminal
                                                // semantics support yet; merge the label
                                                // and hint into the terminal's own
                                                // semantics node until the upstreamed
                                                // flterm patches release.
                                                Semantics(
                                                  container: false,
                                                  label:
                                                      '${_connectionName(connection)} remote terminal',
                                                  hint:
                                                      'Activate to focus remote terminal input',
                                                  child: Scrollbar(
                                                    controller: connection
                                                        .scrollController,
                                                    child: TerminalView(
                                                      padding: EdgeInsets.zero,
                                                      controller:
                                                          connection.terminal,
                                                      focusNode:
                                                          connection.focusNode,
                                                      autofocus: identical(
                                                        connection,
                                                        active,
                                                      ),
                                                      showKeyboard: widget
                                                          .controller
                                                          .keyboardOnTap,
                                                      theme: terminalTheme,
                                                      scrollController:
                                                          connection
                                                              .scrollController,
                                                      linkSettings: LinkSettings(
                                                        types: const {
                                                          LinkType.osc8,
                                                          LinkType.text,
                                                        },
                                                        onActivate: (link) =>
                                                            unawaited(
                                                              _openTerminalLink(
                                                                link,
                                                              ),
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                ValueListenableBuilder<
                                                  SessionState
                                                >(
                                                  valueListenable:
                                                      connection.state,
                                                  builder:
                                                      (
                                                        context,
                                                        state,
                                                        _,
                                                      ) => state.isAttached
                                                      ? const SizedBox.shrink()
                                                      : SessionOverlay(
                                                          state: state,
                                                          hasHost: true,
                                                          onReconnect:
                                                              connection
                                                                  .reconnect,
                                                          onPair: () => _pair(),
                                                          onDisconnect: () =>
                                                              unawaited(
                                                                _closeConnection(
                                                                  connection,
                                                                ),
                                                              ),
                                                        ),
                                                ),
                                              ],
                                            ),
                                        ],
                                      ),
                                    ),
                                    TerminalAccessory(
                                      controller: active.terminal,
                                      // On touch the floating pad's logo opens
                                      // the sidebar; the accessory logo serves
                                      // wide desktop layouts only.
                                      showSidebarToggle: wide && !touchShell,
                                      onToggleSidebar: toggleSidebar,
                                    ),
                                  ],
                                ),
                        ),
                        if (showPad)
                          Positioned(
                            left: _padPosition.dx,
                            top: _padPosition.dy,
                            child: FloatingTerminalPad(
                              controller: active.terminal,
                              onDragged: (delta) => _movePad(delta, paneSize),
                              onToggleSidebar: toggleSidebar,
                            ),
                          ),
                        // Before any terminal opens on narrow touch layouts
                        // there is no accessory or pad to hold the logo; a
                        // floating corner logo keeps the sidebar reachable.
                        if (touchShell && !wide && active == null)
                          Positioned(
                            left: metrics.size(12),
                            top: metrics.size(8),
                            child: FloatingTerminalLogo(
                              onPressed: () =>
                                  Scaffold.of(context).openDrawer(),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
