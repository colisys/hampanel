import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/terminal_settings.dart';

void main() {
  test('falls back to defaults for missing or unknown fields', () {
    const fallback = TerminalSettings();
    expect(TerminalSettings.fromJson(null).fontSize, fallback.fontSize);
    expect(
      TerminalSettings.fromJson({'cursor': 'weird', 'theme': 'nope'}).cursor,
      'block',
    );
    expect(
      TerminalSettings.fromJson({'cursor': 'weird', 'theme': 'nope'}).theme,
      'follow',
    );
  });

  test('clamps out-of-range values instead of trusting the file', () {
    final settings = TerminalSettings.fromJson({
      'font_size': 400,
      'line_height': 0.1,
      'cursor': 'bar',
      'theme': 'black',
    });
    expect(settings.fontSize, TerminalSettings.maxFontSize);
    expect(settings.lineHeight, TerminalSettings.minLineHeight);
    expect(settings.cursor, 'bar');
    expect(settings.theme, 'black');
  });

  test('round-trips through json', () {
    const original = TerminalSettings(
      fontSize: 15,
      lineHeight: 1.3,
      cursor: 'underline',
      theme: 'classic',
    );
    final restored = TerminalSettings.fromJson(original.toJson());
    expect(restored.fontSize, original.fontSize);
    expect(restored.lineHeight, original.lineHeight);
    expect(restored.cursor, original.cursor);
    expect(restored.theme, original.theme);
  });

  test('copyWith clamps adjusted values', () {
    const settings = TerminalSettings();
    expect(
      settings.copyWith(fontSize: 99).fontSize,
      TerminalSettings.maxFontSize,
    );
    expect(
      settings.copyWith(lineHeight: 9).lineHeight,
      TerminalSettings.maxLineHeight,
    );
  });
}
