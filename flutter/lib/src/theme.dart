import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';

const zukoIvory = Color(0xffeeeed5);
const zukoMutedIvory = Color(0xffd5ceb4);
const zukoCharcoal = Color(0xff323639);
const zukoRed = Color(0xffc5404a);
const zukoDeepRed = Color(0xff520808);
const zukoTan = Color(0xffb49d7b);

const _lightWindow = Color(0xfff7f6ef);
const _lightSurface = Color(0xfffffdf3);
const _darkWindow = Color(0xff25292b);
const _darkSurface = Color(0xff323639);
const _darkAccent = Color(0xffe06b73);

ThemeData buildZukoTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final seed = dark ? _darkAccent : zukoRed;
  final generated = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  final scheme = generated.copyWith(
    primary: seed,
    onPrimary: dark ? const Color(0xff3b080d) : Colors.white,
    primaryContainer: dark ? const Color(0xff5a1c22) : const Color(0xfff5d5d7),
    onPrimaryContainer: dark ? const Color(0xffffdadc) : zukoDeepRed,
    secondary: dark ? const Color(0xffd2b58e) : const Color(0xff80694f),
    onSecondary: dark ? const Color(0xff342514) : Colors.white,
    secondaryContainer: dark
        ? const Color(0xff4b3a27)
        : const Color(0xffeadbc4),
    onSecondaryContainer: dark
        ? const Color(0xffffddaf)
        : const Color(0xff2d2114),
    surface: dark ? _darkWindow : _lightWindow,
    onSurface: dark ? zukoIvory : zukoCharcoal,
    surfaceContainerLowest: dark ? const Color(0xff1c1f20) : _lightSurface,
    surfaceContainerLow: dark
        ? const Color(0xff2b2f31)
        : const Color(0xfff1efe5),
    surfaceContainer: dark ? _darkSurface : const Color(0xffeae7dc),
    surfaceContainerHigh: dark
        ? const Color(0xff3a3e40)
        : const Color(0xffe2ded2),
    surfaceContainerHighest: dark
        ? const Color(0xff454a4c)
        : const Color(0xffd8d2c3),
    onSurfaceVariant: dark ? zukoMutedIvory : const Color(0xff625d54),
    outline: dark ? const Color(0xff858782) : const Color(0xff81796d),
    outlineVariant: dark ? const Color(0xff505456) : const Color(0xffcbc5b8),
  );
  final textTheme = ThemeData(brightness: brightness).textTheme.apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
  final controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(9),
  );

  return ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    useMaterial3: true,
    splashFactory: NoSplash.splashFactory,
    hoverColor: scheme.onSurface.withValues(alpha: 0.06),
    focusColor: scheme.primary.withValues(alpha: 0.16),
    highlightColor: Colors.transparent,
    textTheme: textTheme.copyWith(
      titleLarge: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      titleMedium: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      labelMedium: textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 1,
      backgroundColor: scheme.surfaceContainerLow,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: dark ? 0.42 : 0.18),
      toolbarHeight: 52,
      titleTextStyle: textTheme.titleMedium?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: BorderSide(color: scheme.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        elevation: 0,
        minimumSize: const Size(44, 42),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: controlShape,
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 42),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        side: BorderSide(color: scheme.outlineVariant),
        shape: controlShape,
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(40, 40),
        shape: controlShape,
        textStyle: textTheme.labelLarge,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      minTileHeight: 48,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      selectedColor: scheme.onPrimaryContainer,
      selectedTileColor: scheme.primaryContainer,
      iconColor: scheme.onSurfaceVariant,
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      width: 320,
      shape: const RoundedRectangleBorder(),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? zukoIvory : zukoCharcoal,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: dark ? zukoCharcoal : zukoIvory,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? zukoIvory : zukoCharcoal,
        borderRadius: BorderRadius.circular(7),
      ),
      textStyle: textTheme.bodySmall?.copyWith(
        color: dark ? zukoCharcoal : zukoIvory,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.onPrimary
            : scheme.onSurfaceVariant,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
  );
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
      'Noto Sans Mono',
      'Noto Emoji',
      'Noto Sans Symbols 2',
    ],
    fontSize: fontSize,
  );
}
