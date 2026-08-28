import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';

import 'model.dart';

const zukoIvory = Color(0xffeeeed5);
const zukoCharcoal = Color(0xff323639);
const zukoRed = Color(0xffc5404a);
const _darkAccent = Color(0xffe06b73);

ThemeData buildZukoTheme(
  Brightness brightness, {
  AppInterfaceSize interfaceSize = AppInterfaceSize.standard,
}) {
  final base = brightness == Brightness.dark
      ? YaruVariant.adwaitaRed.darkTheme
      : YaruVariant.adwaitaRed.theme;
  final textScale = switch (interfaceSize) {
    AppInterfaceSize.compact => 0.95,
    AppInterfaceSize.standard => 1.0,
    AppInterfaceSize.comfortable => 1.1,
  };
  final visualDensity = switch (interfaceSize) {
    AppInterfaceSize.compact => VisualDensity.compact,
    AppInterfaceSize.standard => VisualDensity.standard,
    AppInterfaceSize.comfortable => const VisualDensity(
      horizontal: 1,
      vertical: 1,
    ),
  };

  return base.copyWith(
    visualDensity: visualDensity,
    textTheme: base.textTheme.apply(fontSizeFactor: textScale),
    extensions: [
      ...base.extensions.values,
      ZukoMetrics.forInterfaceSize(interfaceSize),
    ],
  );
}

@immutable
class ZukoMetrics extends ThemeExtension<ZukoMetrics> {
  const ZukoMetrics({required this.scale});

  const ZukoMetrics.compact() : scale = 0.9;
  const ZukoMetrics.standard() : scale = 1.0;
  const ZukoMetrics.comfortable() : scale = 1.15;

  factory ZukoMetrics.forInterfaceSize(AppInterfaceSize interfaceSize) =>
      switch (interfaceSize) {
        AppInterfaceSize.compact => const ZukoMetrics.compact(),
        AppInterfaceSize.standard => const ZukoMetrics.standard(),
        AppInterfaceSize.comfortable => const ZukoMetrics.comfortable(),
      };

  static const minimumMainPaneWidth = 460.0;

  final double scale;

  double size(double value) => value * scale;
  double get sidebarWidth => size(300);
  double get collapsedSidebarWidth => size(56);
  double get sidebarHeaderHeight => size(52);
  double get tabBarHeight => size(42);
  double get tabHeight => size(32);
  double get terminalAccessoryHeight => size(kYaruButtonHeight);
  double get terminalAccessoryItemWidth => size(kYaruButtonHeight);
  double get terminalAccessoryGroupSpacing => size(6);
  double get wideLayoutBreakpoint => sidebarWidth + minimumMainPaneWidth;

  static ZukoMetrics of(BuildContext context) =>
      Theme.of(context).extension<ZukoMetrics>() ??
      const ZukoMetrics.standard();

  @override
  ZukoMetrics copyWith({double? scale}) =>
      ZukoMetrics(scale: scale ?? this.scale);

  @override
  ZukoMetrics lerp(covariant ZukoMetrics? other, double t) {
    if (other == null) return this;
    return ZukoMetrics(scale: scale + (other.scale - scale) * t);
  }
}

TerminalTheme buildZukoTerminalTheme({
  required Brightness brightness,
  required double fontSize,
}) {
  final dark = brightness == Brightness.dark;
  final base = dark ? TerminalTheme.dark() : TerminalTheme.light();
  final ansi = base.palette.ansiColors.toList();
  ansi[1] = zukoRed;
  ansi[9] = dark ? _darkAccent : const Color(0xffa52f39);
  final background = dark ? const Color(0xff202426) : const Color(0xfffcfbf2);
  final foreground = dark ? zukoIvory : zukoCharcoal;

  return base.copyWith(
    palette: base.palette.copyWith(
      ansiColors: ansi,
      background: background,
      foreground: foreground,
    ),
    cursor: CursorTheme(
      color: DynamicColor.fixed(dark ? _darkAccent : zukoRed),
      text: DynamicColor.fixed(background),
    ),
    selection: SelectionTheme(
      background: DynamicColor.fixed(
        dark ? const Color(0xff643137) : const Color(0xffefd2d3),
      ),
      foreground: DynamicColor.fixed(foreground),
    ),
    fontFamily: 'JetBrains Mono',
    fontFamilyFallback: const [
      'JetBrainsMono Nerd Font Mono',
      'Noto Sans Mono',
      'Noto Emoji',
      'Noto Sans Symbols 2',
      'Noto Sans JP',
      'Noto Sans KR',
    ],
    fontSize: fontSize,
  );
}
