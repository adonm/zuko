import 'package:flutter/material.dart' hide Key;
import 'package:libghostty/libghostty.dart';

const terminalNavigationKeys = <({String label, Key key})>[
  (label: 'Home', key: Key.home),
  (label: 'End', key: Key.end),
  (label: 'PgUp', key: Key.pageUp),
  (label: 'PgDn', key: Key.pageDown),
  (label: 'Ins', key: Key.insert),
  (label: 'Del', key: Key.delete),
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
  Key.arrowUp => Icons.keyboard_arrow_up,
  Key.arrowDown => Icons.keyboard_arrow_down,
  Key.arrowLeft => Icons.keyboard_arrow_left,
  Key.arrowRight => Icons.keyboard_arrow_right,
  _ => throw ArgumentError.value(key, 'key', 'not an arrow key'),
};

bool showConnectionTabs(int connectionCount) => connectionCount > 1;

/// On Linux the stock GTK3 embedder reports touchscreen pointers as mouse
/// (flutter/flutter#90366). Allow mouse drags to scroll so touch drags keep
/// working, and let the terminal route mouse-kind drags to its Scrollable
/// instead of selecting.

/// CLI punctuation ordered by how often shells, vim, and emacs need them.
/// Grouped left-to-right as: piping/home, shell metacharacters, redirects,
/// anchors/operators, quotes/grouping, and common separators.
const terminalPunctuationKeys = <String>[
  '|',
  '~',
  r'`',
  r'\',
  r'$',
  '<',
  '>',
  '^',
  '&',
  '*',
  '%',
  '#',
  '@',
  '!',
  '/',
  '?',
  '-',
  '_',
  '=',
  '+',
  '[',
  ']',
  '{',
  '}',
  '(',
  ')',
  ':',
  ';',
  "'",
  '"',
  ',',
  '.',
];

/// Punctuation keys shown in the accessory for [platform]. Touch soft
/// keyboards (iOS and Android) already provide every one of these characters
/// on their number and symbol layers, so the group is omitted there to keep
/// the strip short.
List<String> terminalPunctuationKeysFor(TargetPlatform platform) =>
    platform == TargetPlatform.iOS || platform == TargetPlatform.android
    ? const []
    : terminalPunctuationKeys;
