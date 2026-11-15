import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'enrollment.dart';

/// 管理端本地偏好：更新通道、GitHub 镜像与概览刷新频率。
/// 保存在用户配置目录，不随受控端同步。
class ClientSettings extends ChangeNotifier {
  ClientSettings._();

  static final ClientSettings instance = ClientSettings._();
  static const refreshChoices = [2, 3, 5, 10, 30];

  int overviewRefreshSeconds = 3;
  String? updateChannel;
  String githubMirror = '';
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = _file();
      if (!file.existsSync()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final seconds = (decoded['overview_refresh_seconds'] as num?)?.toInt();
      if (seconds != null && refreshChoices.contains(seconds)) {
        overviewRefreshSeconds = seconds;
      }
      final channel = decoded['update_channel'];
      if (channel == 'nightly' || channel == 'stable') {
        updateChannel = channel as String;
      }
      githubMirror = (decoded['github_mirror'] as String?)?.trim() ?? '';
      notifyListeners();
    } catch (_) {
      // 本地偏好损坏时退回默认值。
    }
  }

  Future<void> save() async {
    try {
      final file = _file();
      file.parent.createSync(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'overview_refresh_seconds': overviewRefreshSeconds,
          'update_channel': updateChannel,
          'github_mirror': githubMirror,
        }),
      );
      if (!Platform.isWindows) {
        await Process.run('chmod', ['600', file.path]);
      }
    } catch (_) {
      // 写入失败不影响当前会话。
    }
    notifyListeners();
  }

  File _file() =>
      File('${Enrollment.configDirectory().path}/client_settings.json');
}
