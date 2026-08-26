import 'package:flutter/material.dart' hide Key;
import 'package:yaru/yaru.dart';
import 'package:libghostty/libghostty.dart';

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

IconData terminalArrowIcon(Key key) => switch (key) {
  Key.arrowUp => YaruFreedesktopIcons.go_up.icon,
  Key.arrowDown => YaruFreedesktopIcons.go_down.icon,
  Key.arrowLeft => YaruFreedesktopIcons.go_previous.icon,
  Key.arrowRight => YaruFreedesktopIcons.go_next.icon,
  _ => throw ArgumentError.value(key, 'key', 'not an arrow key'),
};

bool showConnectionTabs(int connectionCount) => connectionCount > 1;

/// On Linux the stock GTK3 embedder reports touchscreen pointers as mouse
/// (flutter/flutter#90366). Allow mouse drags to scroll so touch drags keep
/// working, and let the terminal route mouse-kind drags to its Scrollable
/// instead of selecting.
