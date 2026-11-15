import 'package:material_ui/material_ui.dart';

class _Palette {
  const _Palette({
    required this.paper,
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.ink,
    required this.inkSoft,
    required this.muted,
    required this.accent,
    required this.danger,
    required this.warning,
  });

  final Color paper;
  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color border;
  final Color ink;
  final Color inkSoft;
  final Color muted;
  final Color accent;
  final Color danger;
  final Color warning;
}

const _lightPalette = _Palette(
  paper: Color(0xFFF3EEE2),
  background: Color(0xFFF3EEE2),
  surface: Color(0xFFFFFBF3),
  surfaceAlt: Color(0xFFE8E0CE),
  border: Color(0xFF161616),
  ink: Color(0xFF161616),
  inkSoft: Color(0xFF3B362E),
  muted: Color(0xFF6B6457),
  accent: Color(0xFFD7263D),
  danger: Color(0xFF8E1B1B),
  warning: Color(0xFF9A6100),
);

const _darkPalette = _Palette(
  paper: Color(0xFF121110),
  background: Color(0xFF121110),
  surface: Color(0xFF1B1916),
  surfaceAlt: Color(0xFF27231C),
  border: Color(0xFFF2E9D6),
  ink: Color(0xFFF2E9D6),
  inkSoft: Color(0xFFD9CEBA),
  muted: Color(0xFFA99D87),
  accent: Color(0xFFFF4B5C),
  danger: Color(0xFFFF6B6B),
  warning: Color(0xFFE5A94E),
);

var _palette = _lightPalette;
var _brightness = Brightness.light;

void setHampanelBrightness(Brightness brightness) {
  _brightness = brightness;
  _palette = brightness == Brightness.dark ? _darkPalette : _lightPalette;
}

Brightness get hampanelBrightness => _brightness;

Color get hampanelPaper => _palette.paper;
Color get hampanelBackground => _palette.background;
Color get hampanelSurface => _palette.surface;
Color get hampanelSurfaceAlt => _palette.surfaceAlt;
Color get hampanelBorder => _palette.border;
Color get hampanelInk => _palette.ink;
Color get hampanelInkSoft => _palette.inkSoft;
Color get hampanelMuted => _palette.muted;
Color get hampanelAccent => _palette.accent;
Color get hampanelDanger => _palette.danger;
Color get hampanelWarning => _palette.warning;

List<BoxShadow> get mangaShadow => [
  BoxShadow(color: _palette.ink, offset: const Offset(5, 5), blurRadius: 0),
];

List<BoxShadow> get mangaShadowSmall => [
  BoxShadow(color: _palette.ink, offset: const Offset(2, 2), blurRadius: 0),
];

BorderSide get mangaBorder => BorderSide(color: _palette.ink, width: 2);

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
  fontFamily: 'DejaVu Sans Mono',
  fontFamilyFallback: [
    'JetBrains Mono',
    'Noto Sans Mono',
    'Liberation Mono',
    'Consolas',
    'Menlo',
  ],
  fontSize: 12.5,
  height: 1.45,
);

TextStyle get mangaKicker => TextStyle(
  fontFamily: 'DejaVu Sans Mono',
  fontFamilyFallback: const [
    'JetBrains Mono',
    'Noto Sans Mono',
    'Liberation Mono',
    'Consolas',
    'Menlo',
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
        brightness: _brightness,
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
        scrim: hampanelPaper,
      );

  final base = ThemeData(
    useMaterial3: true,
    brightness: _brightness,
    colorScheme: scheme,
    fontFamily: _sansFamily,
    fontFamilyFallback: _sansFallback,
    scaffoldBackgroundColor: hampanelBackground,
    cardTheme: CardThemeData(
      color: hampanelSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        side: mangaBorder,
      ),
    ),
    appBarTheme: AppBarTheme(
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
    dividerTheme: DividerThemeData(
      color: hampanelInk,
      thickness: 1.4,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: hampanelSurface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      hintStyle: TextStyle(
        fontFamily: _sansFamily,
        fontFamilyFallback: _sansFallback,
        color: hampanelMuted,
      ),
      labelStyle: TextStyle(
        fontFamily: _sansFamily,
        fontFamilyFallback: _sansFallback,
        color: hampanelInkSoft,
        fontWeight: FontWeight.w600,
      ),
      border: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: mangaBorder,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: mangaBorder,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: hampanelAccent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: hampanelDanger, width: 2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: hampanelDanger, width: 2),
      ),
    ),
    dataTableTheme: DataTableThemeData(
      headingTextStyle: TextStyle(
        fontFamily: _sansFamily,
        fontFamilyFallback: _sansFallback,
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: hampanelInk,
        letterSpacing: 0.2,
      ),
      dataTextStyle: TextStyle(
        fontFamily: _sansFamily,
        fontFamilyFallback: _sansFallback,
        fontSize: 12.5,
        color: hampanelInkSoft,
      ),
      dividerThickness: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: hampanelInk,
      contentTextStyle: TextStyle(color: hampanelSurface),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(3),
        side: mangaBorder,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: hampanelSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
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
    popupMenuTheme: PopupMenuThemeData(
      color: hampanelSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        side: mangaBorder,
      ),
      textStyle: TextStyle(fontSize: 13, color: hampanelInk),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: hampanelInk,
        borderRadius: const BorderRadius.all(Radius.circular(3)),
      ),
      textStyle: TextStyle(color: hampanelSurface, fontSize: 11.5),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: hampanelSurface,
      selectedColor: hampanelInk,
      side: mangaBorder,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
      ),
      labelStyle: TextStyle(
        fontSize: 12,
        color: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? hampanelSurface
              : hampanelInk,
        ),
      ),
      secondaryLabelStyle: TextStyle(fontSize: 12, color: hampanelSurface),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
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
      thumbColor: WidgetStatePropertyAll(hampanelSurface),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? hampanelAccent
            : hampanelSurfaceAlt,
      ),
      trackOutlineColor: WidgetStatePropertyAll(hampanelInk),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(hampanelInk.withValues(alpha: 0.35)),
      radius: const Radius.circular(2),
      thickness: const WidgetStatePropertyAll(8),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: hampanelAccent,
      selectionColor: hampanelAccent.withValues(alpha: 0.20),
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
