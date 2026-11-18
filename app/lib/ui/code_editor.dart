import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart' as re;
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import '../core/api_client.dart';
import '../core/format.dart';
import '../core/models/recycle_entry.dart';
import 'theme.dart';
import 'widgets.dart';

const double _editorHeaderHeight = 48;

enum CodeLanguage {
  plain('文本'),
  ini('INI / systemd'),
  toml('TOML'),
  nginx('Nginx'),
  yaml('YAML'),
  json('JSON'),
  dockerfile('Dockerfile'),
  bash('Shell'),
  properties('Properties');

  const CodeLanguage(this.label);

  final String label;
}

class CodeEditorPane extends StatefulWidget {
  const CodeEditorPane({
    super.key,
    required this.initialText,
    this.language = CodeLanguage.plain,
    this.readOnly = false,
    this.onChanged,
    this.onSave,
    this.showToolbar = true,
    this.wordWrap = false,
  });

  final String initialText;
  final CodeLanguage language;
  final bool readOnly;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSave;
  final bool showToolbar;
  final bool wordWrap;

  @override
  State<CodeEditorPane> createState() => CodeEditorPaneState();
}

class CodeEditorPaneState extends State<CodeEditorPane> {
  late final re.CodeLineEditingController _controller;
  late final re.CodeFindController _findController;

  String get text => _controller.text;

  @override
  void initState() {
    super.initState();
    _controller = re.CodeLineEditingController.fromText(widget.initialText);
    _findController = re.CodeFindController(_controller);
  }

  @override
  void dispose() {
    _findController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _search() {
    _findController.findMode();
    _findController.focusOnFindInput();
  }

  @override
  Widget build(BuildContext context) {
    final theme = _themeFor(widget.language);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showToolbar)
          Container(
            height: _editorHeaderHeight,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: hampanelSurfaceAlt,
              border: Border(
                bottom: BorderSide(color: hampanelBorder, width: 1),
              ),
            ),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    widget.language.label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: hampanelMuted,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '搜索',
                  onPressed: _search,
                  icon: const Icon(Icons.search, size: 18),
                ),
                if (widget.onSave != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: FilledButton.icon(
                      onPressed: () => widget.onSave!(_controller.text),
                      icon: const Icon(Icons.save_outlined, size: 15),
                      label: const Text('保存'),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: re.CodeEditor(
            controller: _controller,
            findController: _findController,
            readOnly: widget.readOnly,
            showCursorWhenReadOnly: false,
            wordWrap: widget.wordWrap,
            autofocus: false,
            style: re.CodeEditorStyle(
              fontSize: 13,
              fontFamily: 'FiraCode',
              fontFamilyFallback: const [
                'DejaVu Sans Mono',
                'JetBrains Mono',
                'Noto Sans Mono',
                'monospace',
                'Liberation Mono',
                'Consolas',
                'Menlo',
              ],
              fontHeight: 1.5,
              textColor: hampanelInk,
              hintTextColor: hampanelMuted,
              backgroundColor: hampanelSurface,
              selectionColor: hampanelAccent.withValues(alpha: 0.18),
              highlightColor: hampanelWarning.withValues(alpha: 0.28),
              cursorColor: hampanelAccent,
              cursorLineColor: hampanelSurfaceAlt,
              chunkIndicatorColor: hampanelMuted,
              codeTheme: theme,
            ),
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            indicatorBuilder:
                (context, editingController, chunkController, notifier) {
                  return re.DefaultCodeLineNumber(
                    controller: editingController,
                    notifier: notifier,
                  );
                },
            leadingDivider: Container(width: 1, color: hampanelBorder),
            findBuilder: (context, controller, readOnly) =>
                _FindPanel(controller: controller, readOnly: readOnly),
            toolbarController: const _SelectionToolbar(),
            onChanged: (_) => widget.onChanged?.call(_controller.text),
          ),
        ),
      ],
    );
  }

  re.CodeHighlightTheme? _themeFor(CodeLanguage language) {
    final Mode? mode;
    final String? key;
    switch (language) {
      case CodeLanguage.plain:
        mode = null;
        key = null;
      case CodeLanguage.ini:
        mode = langIni;
        key = 'ini';
      case CodeLanguage.toml:
        mode = langIni;
        key = 'toml';
      case CodeLanguage.nginx:
        mode = langNginx;
        key = 'nginx';
      case CodeLanguage.yaml:
        mode = langYaml;
        key = 'yaml';
      case CodeLanguage.json:
        mode = langJson;
        key = 'json';
      case CodeLanguage.dockerfile:
        mode = langDockerfile;
        key = 'dockerfile';
      case CodeLanguage.bash:
        mode = langBash;
        key = 'bash';
      case CodeLanguage.properties:
        mode = langProperties;
        key = 'properties';
    }
    if (mode == null || key == null) return null;
    return re.CodeHighlightTheme(
      languages: {key: re.CodeHighlightThemeMode(mode: mode)},
      theme: hampanelBrightness == Brightness.dark
          ? atomOneDarkTheme
          : atomOneLightTheme,
    );
  }
}

class CodeEditorPage extends StatefulWidget {
  const CodeEditorPage({
    super.key,
    required this.title,
    required this.initialText,
    this.language = CodeLanguage.plain,
    this.api,
    this.filePath,
  });

  final String title;
  final String initialText;
  final CodeLanguage language;
  final ApiClient? api;
  final String? filePath;

  @override
  State<CodeEditorPage> createState() => _CodeEditorPageState();
}

class _CodeEditorPageState extends State<CodeEditorPage> {
  final _editorKey = GlobalKey<CodeEditorPaneState>();
  List<FileVersion> _versions = const [];
  bool _historyLoading = false;
  bool _historyOpen = false;
  String? _historyError;

  @override
  void initState() {
    super.initState();
    if (widget.api != null && widget.filePath != null) {
      _loadHistory();
    }
  }

  Future<void> _loadHistory() async {
    final api = widget.api;
    final path = widget.filePath;
    if (api == null || path == null) return;
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      final json = await api.getJson(
        '/api/v1/files/versions',
        query: {'path': path},
      );
      final map = json as Map<String, dynamic>;
      final versions = ((map['versions'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(FileVersion.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _versions = versions;
        _historyLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _historyError = describeError(error);
        _historyLoading = false;
      });
    }
  }

  void _save() {
    Navigator.of(context).pop(_editorKey.currentState?.text);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final hasHistory = widget.api != null && widget.filePath != null;
    final editor = CodeEditorPane(
      key: _editorKey,
      initialText: widget.initialText,
      language: widget.language,
    );
    final history = hasHistory ? _historyPanel() : null;
    return Scaffold(
      backgroundColor: hampanelBackground,
      appBar: AppBar(
        backgroundColor: hampanelBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (hasHistory && !wide)
            IconButton(
              tooltip: '文件历史',
              onPressed: () => setState(() => _historyOpen = !_historyOpen),
              icon: Icon(
                _historyOpen ? Icons.history_toggle_off : Icons.history,
                size: 20,
              ),
            ),
          IconButton(
            tooltip: '保存',
            onPressed: _save,
            icon: const Icon(Icons.save_outlined, size: 20),
          ),
        ],
      ),
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
                    child: editor,
                  ),
                ),
                if (history != null) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(width: 300, child: history),
                ],
              ],
            )
          : Column(
              children: [
                Expanded(child: editor),
                if (history != null && _historyOpen)
                  SizedBox(height: 210, child: history),
              ],
            ),
    );
  }

  Widget _historyPanel() {
    if (_historyLoading) return const LoadingView();
    if (_historyError != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: ErrorBanner(message: _historyError!, onRetry: _loadHistory),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '文件历史',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: '刷新',
                visualDensity: VisualDensity.compact,
                onPressed: _loadHistory,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _versions.isEmpty
              ? Center(
                  child: Text(
                    '暂无修改记录',
                    style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                  ),
                )
              : ListView.separated(
                  itemCount: _versions.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final version = _versions[index];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.history, size: 17),
                      title: Text(
                        formatDateTime(version.createdAt),
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      subtitle: Text(
                        formatBytes(version.size),
                        style: const TextStyle(fontSize: 10.5),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _FindPanel extends StatelessWidget implements PreferredSizeWidget {
  const _FindPanel({required this.controller, required this.readOnly});

  final re.CodeFindController controller;
  final bool readOnly;

  static const double _height = 34;

  @override
  Size get preferredSize => controller.value == null
      ? Size.zero
      : const Size(double.infinity, _height);

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    if (value == null) return const SizedBox.shrink();
    final result = value.result;
    final label = result == null
        ? '无匹配'
        : '${result.index + 1}/${result.matches.length}';
    return Container(
      height: _height,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: hampanelSurfaceAlt,
        border: Border(bottom: BorderSide(color: hampanelBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller.findInputController,
              focusNode: controller.findInputFocusNode,
              onSubmitted: (_) => controller.nextMatch(),
              style: const TextStyle(fontSize: 11.5),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 7,
                ),
                hintText: '搜索内容',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 10.5, color: hampanelMuted)),
          _FindButton(
            tooltip: '上一个',
            onPressed: result == null ? null : controller.previousMatch,
            icon: Icons.keyboard_arrow_up,
          ),
          _FindButton(
            tooltip: '下一个',
            onPressed: result == null ? null : controller.nextMatch,
            icon: Icons.keyboard_arrow_down,
          ),
          _FindButton(
            tooltip: '关闭',
            onPressed: controller.close,
            icon: Icons.close,
          ),
        ],
      ),
    );
  }
}

class _FindButton extends StatelessWidget {
  const _FindButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
    );
  }
}

class _SelectionToolbar implements re.SelectionToolbarController {
  const _SelectionToolbar();

  @override
  void hide(BuildContext context) {}

  @override
  void show({
    required BuildContext context,
    required re.CodeLineEditingController controller,
    required TextSelectionToolbarAnchors anchors,
    Rect? renderRect,
    required LayerLink layerLink,
    required ValueNotifier<bool> visibility,
  }) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final overlayBox = overlay.context.findRenderObject();
    if (overlayBox is! RenderBox) return;
    final position = RelativeRect.fromSize(
      anchors.primaryAnchor & const Size(180, double.infinity),
      overlayBox.size,
    );
    showMenu<void>(
      context: context,
      position: position,
      items: [
        PopupMenuItem<void>(onTap: controller.cut, child: const Text('剪切')),
        PopupMenuItem<void>(onTap: controller.copy, child: const Text('复制')),
        PopupMenuItem<void>(onTap: controller.paste, child: const Text('粘贴')),
      ],
    ).whenComplete(() => visibility.value = false);
  }
}
