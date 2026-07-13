import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';

const zukoIvory = Color(0xffeeeed5);
const zukoCharcoal = Color(0xff323639);
const zukoRed = Color(0xffc5404a);
const _darkAccent = Color(0xffe06b73);

ThemeData buildZukoTheme(Brightness brightness) => brightness == Brightness.dark
    ? YaruVariant.adwaitaRed.darkTheme
    : YaruVariant.adwaitaRed.theme;

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
