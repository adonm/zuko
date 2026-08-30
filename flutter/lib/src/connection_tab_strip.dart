import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'model.dart';
import 'session_state.dart';

import 'terminal_connection.dart';
import 'theme.dart';

class ConnectionTabStrip extends StatefulWidget {
  const ConnectionTabStrip({
    super.key,
    required this.selectedIndex,
    required this.connections,
    required this.labelFor,
    required this.onSelected,
    required this.onClose,
  });

  final int selectedIndex;
  final List<TerminalConnection> connections;
  final String Function(TerminalConnection connection) labelFor;
  final ValueChanged<int> onSelected;
  final ValueChanged<TerminalConnection> onClose;

  @override
  State<ConnectionTabStrip> createState() => _ConnectionTabStripState();
}

class _ConnectionTabStripState extends State<ConnectionTabStrip>
    with SingleTickerProviderStateMixin {
  final _scrollController = ScrollController();
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: widget.connections.length,
      initialIndex: widget.selectedIndex,
      vsync: this,
    );
  }

  @override
  void didUpdateWidget(ConnectionTabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connections.length != widget.connections.length) {
      final previous = _tabController;
      _tabController = TabController(
        length: widget.connections.length,
        initialIndex: widget.selectedIndex.clamp(
          0,
          math.max(0, widget.connections.length - 1),
        ),
        vsync: this,
      );
      previous.dispose();
    }
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _tabController.index = widget.selectedIndex;
      _revealSelectedTab();
    }
    if (oldWidget.connections.length != widget.connections.length) {
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
        widget.connections.length * ZukoMetrics.of(context).size(128),
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
  Widget build(BuildContext context) {
    final metrics = ZukoMetrics.of(context);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = math.max(
            constraints.maxWidth,
            widget.connections.length * metrics.size(128),
          );
          return SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: SizedBox(
                height: metrics.tabBarHeight,
                child: TabBar(
                  controller: _tabController,
                  onTap: _selected,
                  tabs: [
                    for (final connection in widget.connections)
                      Tab(
                        key: ObjectKey(connection),
                        height: metrics.tabHeight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ValueListenableBuilder<SessionState>(
                              valueListenable: connection.state,
                              builder: (context, state, _) => Icon(
                                _tabStatusIcon(state),
                                size: metrics.size(14),
                                color: _tabStatusColor(context, state),
                              ),
                            ),
                            SizedBox(width: metrics.size(6)),
                            Flexible(
                              child: ValueListenableBuilder<SavedHost>(
                                valueListenable: connection.host,
                                builder: (context, host, _) => Text(
                                  host.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            SizedBox(width: metrics.size(2)),
                            IconButton(
                              tooltip: 'Close ${widget.labelFor(connection)}',
                              onPressed: () => widget.onClose(connection),
                              icon: Icon(Icons.close, size: metrics.size(14)),
                              padding: EdgeInsets.zero,
                              constraints: BoxConstraints.tightFor(
                                width: metrics.size(28),
                                height: metrics.size(28),
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
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

IconData _tabStatusIcon(SessionState state) => switch (state.phase) {
  SessionPhase.attached => Icons.link,
  SessionPhase.connecting => Icons.link,
  SessionPhase.retrying => Icons.link_off,
  SessionPhase.ended || SessionPhase.failed => Icons.link_off,
  SessionPhase.rejected => Icons.link_off,
};

Color _tabStatusColor(BuildContext context, SessionState state) {
  final colors = Theme.of(context).colorScheme;
  return switch (state.phase) {
    // In-progress states read as "busy" in the accent color; failures fade.
    SessionPhase.connecting || SessionPhase.retrying => colors.primary,
    SessionPhase.attached => colors.onSurfaceVariant,
    SessionPhase.ended || SessionPhase.failed => colors.onSurfaceVariant,
    SessionPhase.rejected => colors.error,
  };
}
