import 'package:material_ui/material_ui.dart';

const Color hampanelBackground = Color(0xFF0A0F13);
const Color hampanelSurface = Color(0xFF111920);
const Color hampanelSurfaceAlt = Color(0xFF16212A);
const Color hampanelBorder = Color(0xFF22303B);
const Color hampanelAccent = Color(0xFF4AD295);
const Color hampanelDanger = Color(0xFFFF6B6B);
const Color hampanelMuted = Color(0xFF8AA0B0);

const TextStyle monospace = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Menlo', 'Consolas', 'DejaVu Sans Mono'],
  fontSize: 12.5,
  height: 1.4,
);

ThemeData buildHampanelTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: hampanelAccent,
        brightness: Brightness.dark,
      ).copyWith(
        surface: hampanelSurface,
        surfaceContainerHighest: hampanelSurfaceAlt,
        primary: hampanelAccent,
        error: hampanelDanger,
        outline: hampanelBorder,
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: hampanelBackground,
    cardTheme: const CardThemeData(
      color: hampanelSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        side: BorderSide(color: hampanelBorder),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: hampanelBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: hampanelBorder,
      thickness: 0.7,
      space: 1,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Color(0xFF0D151B),
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: hampanelBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: hampanelBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: hampanelAccent),
      ),
    ),
    dataTableTheme: const DataTableThemeData(
      headingTextStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: hampanelMuted,
      ),
      dataTextStyle: TextStyle(fontSize: 12.5, color: Color(0xFFD7E2EA)),
      dividerThickness: 0.5,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: hampanelSurfaceAlt,
      contentTextStyle: TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: hampanelAccent),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: hampanelAccent,
        foregroundColor: const Color(0xFF04120C),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
  );
}
