import 'package:material_ui/material_ui.dart';

const Color hampanelPaper = Color(0xFFF3EEE2);
const Color hampanelBackground = hampanelPaper;
const Color hampanelSurface = Color(0xFFFFFBF3);
const Color hampanelSurfaceAlt = Color(0xFFE8E0CE);
const Color hampanelBorder = Color(0xFF161616);
const Color hampanelInk = Color(0xFF161616);
const Color hampanelInkSoft = Color(0xFF3B362E);
const Color hampanelMuted = Color(0xFF6B6457);
const Color hampanelAccent = Color(0xFFD7263D);
const Color hampanelDanger = Color(0xFF8E1B1B);
const Color hampanelWarning = Color(0xFF9A6100);

const List<BoxShadow> mangaShadow = [
  BoxShadow(color: hampanelInk, offset: Offset(5, 5), blurRadius: 0),
];

const List<BoxShadow> mangaShadowSmall = [
  BoxShadow(color: hampanelInk, offset: Offset(2, 2), blurRadius: 0),
];

const BorderSide mangaBorder = BorderSide(color: hampanelInk, width: 2);

const String _sansFamily = 'Noto Sans CJK SC';
const List<String> _sansFallback = [
  'Noto Sans SC',
  'Source Han Sans SC',
  'Noto Sans',
  'PingFang SC',
  'Microsoft YaHei',
  'DejaVu Sans',
  'sans-serif',
];

const TextStyle monospace = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: [
    'JetBrains Mono',
    'Menlo',
    'Consolas',
    'DejaVu Sans Mono',
  ],
  fontSize: 12.5,
  height: 1.45,
);

const TextStyle mangaKicker = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: [
    'JetBrains Mono',
    'Menlo',
    'Consolas',
    'DejaVu Sans Mono',
  ],
  fontSize: 10.5,
  fontWeight: FontWeight.w700,
  letterSpacing: 1.4,
  color: hampanelMuted,
);

ThemeData buildHampanelTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: hampanelAccent,
        brightness: Brightness.light,
      ).copyWith(
        primary: hampanelInk,
        onPrimary: hampanelSurface,
        secondary: hampanelAccent,
        onSecondary: hampanelSurface,
        error: hampanelDanger,
        onError: hampanelSurface,
        surface: hampanelSurface,
        onSurface: hampanelInk,
        surfaceContainerHighest: hampanelSurfaceAlt,
        onSurfaceVariant: hampanelMuted,
        outline: hampanelInk,
        outlineVariant: hampanelBorder,
        shadow: hampanelInk,
        scrim: hampanelInk,
      );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: scheme,
    fontFamily: _sansFamily,
    fontFamilyFallback: _sansFallback,
    scaffoldBackgroundColor: hampanelBackground,
    cardTheme: const CardThemeData(
      color: hampanelSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
        side: mangaBorder,
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: hampanelBackground,
      foregroundColor: hampanelInk,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      shape: Border(bottom: mangaBorder),
      titleTextStyle: TextStyle(
        fontFamily: _sansFamily,
        fontFamilyFallback: _sansFallback,
        fontSize: 18,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.2,
        color: hampanelInk,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: hampanelInk,
      thickness: 1.4,
      space: 1,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: hampanelSurface,
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      hintStyle: TextStyle(color: hampanelMuted),
      labelStyle: TextStyle(
        color: hampanelInkSoft,
        fontWeight: FontWeight.w600,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
        borderSide: mangaBorder,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
        borderSide: mangaBorder,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: hampanelAccent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: hampanelDanger, width: 2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: hampanelDanger, width: 2),
      ),
    ),
    dataTableTheme: const DataTableThemeData(
      headingTextStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: hampanelInk,
        letterSpacing: 0.2,
      ),
      dataTextStyle: TextStyle(fontSize: 12.5, color: hampanelInkSoft),
      dividerThickness: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: hampanelInk,
      contentTextStyle: const TextStyle(color: hampanelSurface),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(3),
        side: const BorderSide(color: hampanelInk, width: 2),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: hampanelSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
        side: mangaBorder,
      ),
      titleTextStyle: TextStyle(
        fontFamily: _sansFamily,
        fontFamilyFallback: _sansFallback,
        fontSize: 18,
        fontWeight: FontWeight.w800,
        color: hampanelInk,
      ),
      contentTextStyle: TextStyle(
        fontFamily: _sansFamily,
        fontFamilyFallback: _sansFallback,
        fontSize: 13,
        color: hampanelInkSoft,
        height: 1.5,
      ),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: hampanelSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
        side: mangaBorder,
      ),
      textStyle: TextStyle(fontSize: 13, color: hampanelInk),
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: hampanelInk,
        borderRadius: BorderRadius.all(Radius.circular(3)),
      ),
      textStyle: TextStyle(color: hampanelSurface, fontSize: 11.5),
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: hampanelSurface,
      selectedColor: hampanelInk,
      side: mangaBorder,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
      ),
      labelStyle: TextStyle(fontSize: 12, color: hampanelInk),
      secondaryLabelStyle: TextStyle(fontSize: 12, color: hampanelSurface),
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: hampanelInk,
      linearTrackColor: hampanelSurfaceAlt,
      circularTrackColor: hampanelSurfaceAlt,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: hampanelInk,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: hampanelInk,
        foregroundColor: hampanelSurface,
        disabledBackgroundColor: hampanelSurfaceAlt,
        disabledForegroundColor: hampanelMuted,
        elevation: 0,
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(3),
          side: mangaBorder,
        ),
        textStyle: const TextStyle(
          fontFamily: _sansFamily,
          fontFamilyFallback: _sansFallback,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.3,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: hampanelInk,
        backgroundColor: hampanelSurface,
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        side: mangaBorder,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
        textStyle: const TextStyle(
          fontFamily: _sansFamily,
          fontFamilyFallback: _sansFallback,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: hampanelInk),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(hampanelSurface),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? hampanelAccent
            : hampanelSurfaceAlt,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(hampanelInk),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(hampanelInk.withValues(alpha: 0.35)),
      radius: const Radius.circular(2),
      thickness: const WidgetStatePropertyAll(8),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: hampanelAccent,
      selectionColor: Color(0x33D7263D),
      selectionHandleColor: hampanelAccent,
    ),
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: hampanelInk,
      displayColor: hampanelInk,
    ),
  );
}
