import 'package:material_ui/material_ui.dart';

import '../../core/build_info.dart';
import '../../core/client_settings.dart';
import '../../core/client_update.dart';
import '../../core/external.dart';
import '../../core/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Self-update controls for the management client. Used from Settings and
/// from the startup screen, so the client can be updated even when no saved
/// server is reachable.
class ClientUpdatePanel extends StatefulWidget {
  const ClientUpdatePanel({super.key});

  @override
  State<ClientUpdatePanel> createState() => _ClientUpdatePanelState();
}

class _ClientUpdatePanelState extends State<ClientUpdatePanel> {
  final _mirror = TextEditingController();
  ClientRelease? _release;
  String? _channel;
  String? _error;
  bool _checking = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _mirror.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await ClientSettings.instance.load();
    if (!mounted) return;
    setState(() {
      _channel = ClientSettings.instance.updateChannel;
      _mirror.text = ClientSettings.instance.githubMirror;
    });
  }

  Future<void> _save() async {
    if (_channel == null) {
      _toast('请先选择更新通道');
      return;
    }
    setState(() => _saving = true);
    try {
      final settings = ClientSettings.instance;
      settings.updateChannel = _channel;
      settings.githubMirror = _mirror.text.trim();
      await settings.save();
      if (!mounted) return;
      setState(() {
        _release = null;
        _error = null;
      });
      _toast('更新设置已保存');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _check() async {
    final channel = _channel ?? ClientSettings.instance.updateChannel;
    if (channel == null) {
      _toast('请先选择更新通道');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final release = await const ClientUpdateService().fetch(
        channel == 'nightly'
            ? ClientUpdateChannel.nightly
            : ClientUpdateChannel.stable,
        mirror: _mirror.text.trim(),
      );
      if (!mounted) return;
      setState(() => _release = release);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _download() async {
    final release = _release;
    if (release == null) return;
    final url =
        ClientUpdateService.clientAsset(release) ??
        'https://github.com/colisys/hampanel/releases/tag/${release.tag}';
    final opened = await openExternalUrl(url);
    if (!opened) _toast('无法打开下载链接，请手动访问发布页');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  bool get _newer {
    final release = _release;
    final channel = _channel ?? ClientSettings.instance.updateChannel;
    if (release == null || channel == null) return false;
    return ClientUpdateService.isNewer(
      channel: channel == 'nightly'
          ? ClientUpdateChannel.nightly
          : ClientUpdateChannel.stable,
      remoteVersion: release.version,
      localVersion: buildVersion,
      localCommit: buildCommit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final release = _release;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormRow(
          flex: const [2, 3],
          children: [
            DropdownButtonFormField<String>(
              initialValue: _channel,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '更新通道',
                hintText: '请选择通道',
              ),
              items: const [
                DropdownMenuItem(value: 'stable', child: Text('stable（正式版）')),
                DropdownMenuItem(
                  value: 'nightly',
                  child: Text('nightly（每日构建）'),
                ),
              ],
              onChanged: (value) => setState(() => _channel = value),
            ),
            TextField(
              controller: _mirror,
              decoration: const InputDecoration(
                labelText: 'GitHub 镜像（可选）',
                hintText: 'https://ghproxy.example',
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '通道与镜像只保存在本机，用于管理端自身更新。',
          style: TextStyle(fontSize: 11, color: hampanelMuted),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: Text(_saving ? '保存中…' : '保存设置'),
            ),
            OutlinedButton.icon(
              onPressed: _checking ? null : _check,
              icon: _checking
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.system_update_alt, size: 16),
              label: Text(_checking ? '检查中…' : '检查更新'),
            ),
            if (release != null)
              OutlinedButton.icon(
                onPressed: _download,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('下载客户端'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _infoRow('当前版本', fullClientVersion),
        if (release != null) ...[
          _infoRow('最新版本', release.version),
          _infoRow(
            '发布时间',
            formatTimestamp(release.publishedAt?.toIso8601String()),
          ),
          _infoRow('状态', _newer ? '有新版本可用' : '已是最新'),
        ],
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(
            _error!,
            style: TextStyle(fontSize: 11.5, color: hampanelDanger),
          ),
        ],
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: hampanelMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: monospace.copyWith(fontSize: 11.5, color: hampanelInk),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showClientUpdateDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('管理端更新'),
      content: DialogBody(
        maxWidth: 560,
        maxHeight: 560,
        child: const SingleChildScrollView(child: ClientUpdatePanel()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
