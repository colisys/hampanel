import 'dart:io';

import 'package:flutter/services.dart';

class PickedFile {
  const PickedFile(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

/// Android Storage Access Framework bridge. Desktop and iOS keep using their
/// native file dialogs through the existing path prompts.
class NativeFiles {
  NativeFiles._();

  static const _channel = MethodChannel('work.dawncall.hampanel/files');

  static bool get supported => Platform.isAndroid;

  static Future<PickedFile?> pick() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('pick');
    if (result == null) return null;
    final bytes = result['bytes'];
    if (bytes is! Uint8List) return null;
    return PickedFile(result['name'] as String? ?? 'file', bytes);
  }

  static Future<void> openUrl(String url) async {
    await _channel.invokeMethod<void>('openUrl', {'url': url});
  }

  static Future<bool> save(String name, List<int> bytes) async {
    final ok = await _channel.invokeMethod<bool>('save', {
      'name': name,
      'bytes': Uint8List.fromList(bytes),
    });
    return ok ?? false;
  }
}
