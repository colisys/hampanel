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

import 'theme.dart';
import 'widgets.dart';

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
            height: 36,
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
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
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
              fontSize: 12.5,
              fontFamily: 'DejaVu Sans Mono',
              fontFamilyFallback: const [
                'JetBrains Mono',
                'Noto Sans Mono',
                'monospace',
                'Liberation Mono',
                'Consolas',
                'Menlo',
              ],
              fontHeight: 1.45,
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
            padding: const EdgeInsets.all(12),
            indicatorBuilder: (context, editingController, chunkController, notifier) {
              return re.DefaultCodeLineNumber(
                controller: editingController,
                notifier: notifier,
              );
            },
            leadingDivider: Container(width: 1, color: hampanelBorder),
            findBuilder: (context, controller, readOnly) => _FindPanel(
              controller: controller,
              readOnly: readOnly,
            ),
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

/// Dialog helper for one-off edits. The caller gets the edited text back.
Future<String?> showCodeEditorDialog(
  BuildContext context, {
  required String title,
  required String initialText,
  CodeLanguage language = CodeLanguage.plain,
  String? description,
  String saveLabel = '保存',
}) async {
  final key = GlobalKey<CodeEditorPaneState>();
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: DialogBody(
        maxWidth: 900,
        maxHeight: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (description != null) ...[
              Text(
                description,
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              ),
              const SizedBox(height: 8),
            ],
            Expanded(
              child: CodeEditorPane(
                key: key,
                initialText: initialText,
                language: language,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, key.currentState?.text),
          child: Text(saveLabel),
        ),
      ],
    ),
  );
}

class _FindPanel extends StatelessWidget implements PreferredSizeWidget {
  const _FindPanel({required this.controller, required this.readOnly});

  final re.CodeFindController controller;
  final bool readOnly;

  @override
  Size get preferredSize => const Size(double.infinity, 40);

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    if (value == null) return const SizedBox.shrink();
    final result = value.result;
    final label = result == null
        ? '无匹配'
        : '${result.index + 1}/${result.matches.length}';
    return Container(
      height: preferredSize.height,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '搜索内容',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 10.5, color: hampanelMuted)),
          IconButton(
            tooltip: '上一个',
            onPressed: result == null ? null : controller.previousMatch,
            icon: const Icon(Icons.keyboard_arrow_up, size: 18),
          ),
          IconButton(
            tooltip: '下一个',
            onPressed: result == null ? null : controller.nextMatch,
            icon: const Icon(Icons.keyboard_arrow_down, size: 18),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: controller.close,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
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
        PopupMenuItem<void>(
          onTap: controller.cut,
          child: const Text('剪切'),
        ),
        PopupMenuItem<void>(
          onTap: controller.copy,
          child: const Text('复制'),
        ),
        PopupMenuItem<void>(
          onTap: controller.paste,
          child: const Text('粘贴'),
        ),
      ],
    ).whenComplete(() => visibility.value = false);
  }
}
