import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/service.dart';
import '../../core/models/service_config.dart';
import '../../core/session.dart';
import '../../ui/code_editor.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../store/deploy_dialog.dart';
import 'service_logs_page.dart';

class ServiceEditPage extends StatefulWidget {
  const ServiceEditPage({super.key, required this.api, required this.service});

  final ApiClient api;
  final ServiceInfo service;

  @override
  State<ServiceEditPage> createState() => _ServiceEditPageState();
}

class _ServiceEditPageState extends State<ServiceEditPage> {
  ServiceConfig? _config;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  String? _selectedFile;
  String _dropin = '';
  bool _restartAfterSave = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await widget.api.getJson(
        '/api/v1/services/${widget.service.unit}/config',
      );
      final config = ServiceConfig.fromJson(json as Map<String, dynamic>);
      String? dropin;
      for (final file in config.files) {
        if (file.path == config.dropinPath) {
          dropin = file.content;
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _config = config;
        _selectedFile = config.files.isEmpty ? null : config.files.first.path;
        _dropin = dropin ?? '[Service]\n# 在 daemon-reload 后覆盖 vendor unit 配置\n';
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _loading = false;
      });
    }
  }

  ServiceConfigFile? get _selectedConfigFile {
    final config = _config;
    if (config == null || _selectedFile == null) return null;
    for (final file in config.files) {
      if (file.path == _selectedFile) return file;
    }
    return null;
  }

  Future<void> _saveDropin() async {
    final config = _config;
    if (config == null) return;
    setState(() => _busy = true);
    try {
      final json = await widget.api.putJson(
        '/api/v1/services/${widget.service.unit}/config',
        {
          'path': config.dropinPath,
          'content': _dropin,
          'restart': _restartAfterSave,
        },
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('覆盖配置已保存并执行 daemon-reload')),
        );
        await _load();
      } else {
        await showOutputDialog(
          context,
          '保存失败',
          map['output'] as String? ?? '',
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(describeError(error))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(String action) async {
    setState(() => _busy = true);
    try {
      final center = PanelScope.of(context).tasks;
      final task = await center.submit(
        'service.action',
        title: '${widget.service.unit}: $action',
        params: {'unit': widget.service.unit, 'action': action},
      );
      if (mounted) {
        showAppSnackBar(
          context,
          SnackBar(content: Text('已提交任务：${task.title}')),
        );
      }
      if (action == 'start' || action == 'stop' || action == 'restart') {
        unawaited(center.waitFor(task.id).then((_) {
          if (mounted) _load();
        }));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(describeError(error))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openLogs() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ServiceLogsPage(
          api: widget.api,
          unit: widget.service.unit,
          title: '${widget.service.unit} 日志',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.service.unit),
          actions: [
            IconButton(
              tooltip: '日志',
              onPressed: _openLogs,
              icon: const Icon(Icons.receipt_long_outlined),
            ),
            PageRefreshButton(onPressed: _load, refreshing: _loading),
            const SizedBox(width: 8),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '单元文件'),
              Tab(text: '覆盖配置'),
            ],
          ),
        ),
        body: _loading
            ? const LoadingView()
            : _error != null
            ? Padding(
                padding: pageContentPadding(context),
                child: ErrorBanner(message: _error!, onRetry: _load),
              )
            : TabBarView(
                children: [
                  _unitFilesTab(context),
                  _dropinTab(context),
                ],
              ),
      ),
    );
  }

  Widget _unitFilesTab(BuildContext context) {
    final config = _config;
    final file = _selectedConfigFile;
    if (config == null || file == null) {
      return const EmptyState(
        icon: Icons.description_outlined,
        title: '没有可读取的 unit 文件',
      );
    }
    return Padding(
      padding: pageContentPadding(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelCard(
            title: '服务状态',
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusPill(
                  text: widget.service.active,
                  good: widget.service.running,
                ),
                Text(
                  widget.service.description.isEmpty
                      ? widget.service.sub
                      : widget.service.description,
                  style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                ),
                Text(
                  'vendor 文件只读；请使用「覆盖配置」写入 drop-in。',
                  style: TextStyle(fontSize: 10.5, color: hampanelMuted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _selectedFile,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'unit 文件',
              isDense: true,
            ),
            items: [
              for (final item in config.files)
                DropdownMenuItem(
                  value: item.path,
                  child: Text(
                    '${item.path}${item.editable ? ' · 可编辑' : ''}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) => setState(() => _selectedFile = value),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: CodeEditorPane(
              key: ValueKey('unit:${file.path}'),
              initialText: file.content,
              language: CodeLanguage.ini,
              readOnly: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dropinTab(BuildContext context) {
    final config = _config;
    if (config == null) return const SizedBox.shrink();
    return Padding(
      padding: pageContentPadding(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelCard(
            title: '面板托管覆盖',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  config.dropinPath,
                  style: monospace.copyWith(fontSize: 11),
                ),
                const SizedBox(height: 6),
                Text(
                  '保存后执行 systemctl daemon-reload；写入的是面板托管的 drop-in，不直接改 vendor unit。',
                  style: TextStyle(fontSize: 11, color: hampanelMuted),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Checkbox(
                      value: _restartAfterSave,
                      onChanged: (value) => setState(
                        () => _restartAfterSave = value ?? false,
                      ),
                    ),
                    const Text('保存后重启服务'),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _busy ? null : _saveDropin,
                      icon: const Icon(Icons.save_outlined, size: 16),
                      label: Text(_busy ? '保存中…' : '保存并应用'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: CodeEditorPane(
              key: const ValueKey('dropin'),
              initialText: _dropin,
              language: CodeLanguage.ini,
              onChanged: (value) => _dropin = value,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run('start'),
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('启动'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run('stop'),
                icon: const Icon(Icons.stop, size: 16),
                label: const Text('停止'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run('restart'),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重启'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run('reload'),
                icon: const Icon(Icons.sync, size: 16),
                label: const Text('重载'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
