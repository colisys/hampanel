import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import '../../core/api_client.dart';
import '../../core/client_settings.dart';
import '../../core/platform_support.dart';
import '../../core/session.dart';
import '../../core/terminal_settings.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, this.autoConnect = true, this.redisId});

  /// IndexedStack 会构建所有隐藏页；只有当前激活标签才允许自动建连。
  final bool autoConnect;
  final String? redisId;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

/// 一个独立的 PTY 会话：终端缓冲、控制器、焦点与 WebSocket 都只属于它。
class _TerminalSession {
  _TerminalSession({
    required this.id,
    required this.title,
    required this.terminal,
    required this.controller,
    required this.focus,
  });

  final int id;
  String title;
  final Terminal terminal;
  final TerminalController controller;
  final FocusNode focus;

  WebSocket? socket;
  StreamSubscription<dynamic>? subscription;

  /// 每次重连自增，用来丢弃旧连接迟到的回调。
  int generation = 0;
  bool connected = false;
  String status = '待连接';

  bool get socketOpen => socket?.readyState == WebSocket.open;
}

class _TerminalPageState extends State<TerminalPage> {
  final _sessions = <_TerminalSession>[];
  int _sessionSeq = 0;
  int? _activeId;

  TerminalSettings get _settings => ClientSettings.instance.terminal;

  _TerminalSession? get _active {
    for (final session in _sessions) {
      if (session.id == _activeId) return session;
    }
    return _sessions.isEmpty ? null : _sessions.first;
  }

  @override
  void initState() {
    super.initState();
    final session = _createSession();
    _sessions.add(session);
    _activeId = session.id;
    _loadSettings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 仅在页面实际可见时建立会话，避免 IndexedStack 隐藏页发起连接。
      if (mounted && widget.autoConnect) _connect(session);
    });
  }

  Future<void> _loadSettings() async {
    await ClientSettings.instance.load();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant TerminalPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoConnect && !oldWidget.autoConnect) {
      final session = _active;
      if (session != null && !session.connected) _connect(session);
    } else if (!widget.autoConnect && oldWidget.autoConnect) {
      // 离开终端页时释放焦点，避免隐藏页继续吞掉键盘输入。
      _active?.focus.unfocus();
    }
  }

  @override
  void dispose() {
    for (final session in _sessions) {
      session.generation += 1;
      session.subscription?.cancel();
      session.socket?.close();
      session.focus.dispose();
      session.controller.dispose();
    }
    super.dispose();
  }

  _TerminalSession _createSession() {
    final session = _TerminalSession(
      id: ++_sessionSeq,
      title: '会话 $_sessionSeq',
      terminal: Terminal(maxLines: 8000),
      controller: TerminalController(),
      focus: FocusNode(),
    );
    session.terminal.onOutput = (data) {
      if (session.connected && session.socketOpen) session.socket?.add(data);
    };
    session.terminal.onResize = (width, height, _, _) {
      if (session.connected && session.socketOpen) {
        session.socket?.add(
          jsonEncode({'type': 'resize', 'cols': width, 'rows': height}),
        );
      }
    };
    session.terminal.onTitleChange = (title) {
      final trimmed = title.trim();
      if (!mounted || trimmed.isEmpty) return;
      setState(() => session.title = trimmed);
    };
    return session;
  }

  /// 新建会话并切换过去；页面激活时立即建连。
  _TerminalSession _addSession() {
    final session = _createSession();
    setState(() {
      _sessions.add(session);
      _activeId = session.id;
    });
    if (widget.autoConnect) _connect(session);
    return session;
  }

  void _selectSession(int id) {
    if (id == _activeId) return;
    _active?.focus.unfocus();
    setState(() => _activeId = id);
    final session = _active;
    if (session != null && !session.connected) _connect(session);
  }

  Future<void> _closeSession(int id) async {
    final index = _sessions.indexWhere((session) => session.id == id);
    if (index < 0) return;
    final session = _sessions.removeAt(index);
    session.generation += 1;
    await session.subscription?.cancel();
    await session.socket?.close();
    session.focus.dispose();
    session.controller.dispose();
    if (!mounted) return;
    setState(() {
      if (session.id == _activeId) {
        if (_sessions.isEmpty) {
          _activeId = null;
        } else {
          _activeId = _sessions[index.clamp(0, _sessions.length - 1)].id;
        }
      }
    });
    if (_sessions.isEmpty) {
      _addSession();
    } else if (widget.autoConnect) {
      final next = _active;
      if (next != null && !next.connected) _connect(next);
    }
  }

  Future<void> _connect(_TerminalSession? session) async {
    if (session == null) return;
    final generation = ++session.generation;
    final pending = session.subscription;
    session.subscription = null;
    await pending?.cancel();
    await session.socket?.close();
    session.socket = null;
    if (!mounted) return;
    setState(() {
      session.status = '正在建立 mTLS 终端会话';
      session.connected = false;
    });
    try {
      final socket = await PanelScope.of(context).api.openTerminal(
        cols: session.terminal.viewWidth,
        rows: session.terminal.viewHeight,
        redisId: widget.redisId,
      );
      if (!mounted || session.generation != generation) {
        await socket.close();
        return;
      }
      // Application-level heartbeat: the daemon answers WebSocket pings with
      // pongs, so a dead NAT/firewall mapping is detected instead of hanging.
      socket.pingInterval = const Duration(seconds: 20);
      session.socket = socket;
      session.connected = true;
      setState(() => session.status = '已连接');
      session.subscription = socket.listen(
        (data) {
          if (session.generation != generation) return;
          if (data is String) {
            session.terminal.write(data);
          } else if (data is List<int>) {
            session.terminal.write(utf8.decode(data, allowMalformed: true));
          }
        },
        onDone: () {
          if (!mounted || session.generation != generation) return;
          setState(() {
            session.connected = false;
            session.status = '会话已断开';
          });
          session.terminal.write('\r\n\x1b[33m[hampanel] 会话已断开\x1b[0m\r\n');
        },
        onError: (Object error) {
          if (!mounted || session.generation != generation) return;
          setState(() {
            session.connected = false;
            session.status = describeError(error);
          });
        },
      );
    } catch (error) {
      if (!mounted || session.generation != generation) return;
      setState(() {
        session.connected = false;
        session.status = describeError(error);
      });
      session.terminal.write(
        '\r\n\x1b[31m[hampanel] ${describeError(error)}\x1b[0m\r\n',
      );
    }
  }

  void _send(_TerminalSession session, String data) {
    if (!session.connected || !session.socketOpen) return;
    session.socket?.add(data);
  }

  Future<void> _copy() async {
    final session = _active;
    if (session == null) return;
    final selection = session.controller.selection;
    final text = selection != null
        ? session.terminal.buffer.getText(selection)
        : session.terminal.buffer.getText();
    if (text.isEmpty) {
      _toast('没有可复制的内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _toast(selection != null ? '已复制选中内容' : '已复制全部输出');
  }

  Future<void> _paste() async {
    final session = _active;
    if (session == null) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    if (!session.connected) {
      _toast('会话未连接，无法粘贴');
      return;
    }
    session.terminal.paste(text);
    session.controller.clearSelection();
    session.focus.requestFocus();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _applySettings(TerminalSettings next) async {
    ClientSettings.instance.terminal = next;
    if (mounted) setState(() {});
    await ClientSettings.instance.save();
  }

  void _adjustFontSize(double delta) {
    unawaited(
      _applySettings(_settings.copyWith(fontSize: _settings.fontSize + delta)),
    );
  }

  Future<void> _openStyleSettings() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final current = _settings;
          void update(TerminalSettings next) {
            setDialogState(() {});
            unawaited(_applySettings(next));
          }

          return AlertDialog(
            title: const Text('终端外观'),
            content: DialogBody(
              maxWidth: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '仅保存在本机客户端，不影响受控端。',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: hampanelMuted,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _styleSlider(
                    label: '字号',
                    value: current.fontSize,
                    min: TerminalSettings.minFontSize,
                    max: TerminalSettings.maxFontSize,
                    divisions:
                        (TerminalSettings.maxFontSize -
                                TerminalSettings.minFontSize)
                            .round(),
                    format: (value) => value.round().toString(),
                    onChanged: (value) => update(
                      current.copyWith(fontSize: value.roundToDouble()),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _styleSlider(
                    label: '行高',
                    value: current.lineHeight,
                    min: TerminalSettings.minLineHeight,
                    max: TerminalSettings.maxLineHeight,
                    divisions: 12,
                    format: (value) => value.toStringAsFixed(1),
                    onChanged: (value) => update(
                      current.copyWith(
                        lineHeight: (value * 10).roundToDouble() / 10,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: current.cursor,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '光标'),
                    items: const [
                      DropdownMenuItem(value: 'block', child: Text('方块')),
                      DropdownMenuItem(value: 'underline', child: Text('下划线')),
                      DropdownMenuItem(value: 'bar', child: Text('竖线')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      update(current.copyWith(cursor: value));
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: current.theme,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '配色'),
                    items: const [
                      DropdownMenuItem(value: 'follow', child: Text('跟随面板')),
                      DropdownMenuItem(value: 'classic', child: Text('经典终端')),
                      DropdownMenuItem(value: 'black', child: Text('纯黑高对比')),
                    ],
                    onChanged: (value) {
                      if (value != null) update(current.copyWith(theme: value));
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => update(const TerminalSettings()),
                child: const Text('恢复默认'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _styleSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            format(value),
            textAlign: TextAlign.right,
            style: monospace.copyWith(fontSize: 11.5),
          ),
        ),
      ],
    );
  }

  TerminalTheme _theme() {
    switch (_settings.theme) {
      case 'classic':
        return TerminalThemes.defaultTheme;
      case 'black':
        return TerminalThemes.whiteOnBlack;
      default:
        return TerminalTheme(
          cursor: hampanelAccent,
          selection: hampanelAccent.withValues(alpha: 0.3),
          foreground: const Color(0xFFEDE6D6),
          background: const Color(0xFF070B0E),
          black: const Color(0xFF000000),
          red: const Color(0xFFCD3131),
          green: const Color(0xFF0DBC79),
          yellow: const Color(0xFFE5E510),
          blue: const Color(0xFF2472C8),
          magenta: const Color(0xFFBC3FBC),
          cyan: const Color(0xFF11A8CD),
          white: const Color(0xFFE5E5E5),
          brightBlack: const Color(0xFF666666),
          brightRed: const Color(0xFFF14C4C),
          brightGreen: const Color(0xFF23D18B),
          brightYellow: const Color(0xFFF5F543),
          brightBlue: const Color(0xFF3B8EEA),
          brightMagenta: const Color(0xFFD670D6),
          brightCyan: const Color(0xFF29B8DB),
          brightWhite: const Color(0xFFFFFFFF),
          searchHitBackground: const Color(0xFFFFFF2B),
          searchHitBackgroundCurrent: const Color(0xFF31FF26),
          searchHitForeground: const Color(0xFF000000),
        );
    }
  }

  TerminalCursorType get _cursorType {
    switch (_settings.cursor) {
      case 'underline':
        return TerminalCursorType.underline;
      case 'bar':
        return TerminalCursorType.verticalBar;
      default:
        return TerminalCursorType.block;
    }
  }

  /// 在 xterm 默认快捷键之上补齐 macOS（Cmd）与 Ctrl+Shift 变体，
  /// Linux/Windows 的 Ctrl+Shift+C 与 Cmd+C 都能复制选中内容。
  Map<ShortcutActivator, Intent> get _shortcuts => {
    ...defaultTerminalShortcuts,
    const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
        CopySelectionTextIntent.copy,
    const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
        const PasteTextIntent(SelectionChangedCause.keyboard),
    const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
        const PasteTextIntent(SelectionChangedCause.keyboard),
    const SingleActivator(LogicalKeyboardKey.keyA, control: true, shift: true):
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
    const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
  };

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final session = _active;
    return Column(
      children: [
        PageHeader(
          title: widget.redisId == null ? '终端' : 'Redis CLI',
          subtitle: compact ? null : 'PTY 会话通过 WebSocket + mTLS 传输',
          actions: [
            StatusPill(
              text: session?.status ?? '无会话',
              good: session?.connected ?? false,
            ),
            const SizedBox(width: 6),
            if (!compact) ...[
              IconButton(
                tooltip: '复制（有选中内容时仅复制选中）',
                visualDensity: VisualDensity.compact,
                onPressed: session == null ? null : _copy,
                icon: const Icon(Icons.copy_all_outlined, size: 18),
              ),
              IconButton(
                tooltip: '粘贴',
                visualDensity: VisualDensity.compact,
                onPressed: session == null ? null : _paste,
                icon: const Icon(Icons.content_paste_outlined, size: 18),
              ),
              IconButton(
                tooltip: '终端外观',
                visualDensity: VisualDensity.compact,
                onPressed: _openStyleSettings,
                icon: const Icon(Icons.tune_outlined, size: 18),
              ),
              IconButton(
                tooltip: '新建会话',
                visualDensity: VisualDensity.compact,
                onPressed: _addSession,
                icon: const Icon(Icons.add_comment_outlined, size: 18),
              ),
              IconButton(
                tooltip: '重新连接',
                visualDensity: VisualDensity.compact,
                onPressed: session == null ? null : () => _connect(session),
                icon: const Icon(Icons.refresh, size: 18),
              ),
              if (PlatformSupport.isMobile)
                IconButton(
                  tooltip: '切换键盘',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    if (session?.focus.hasFocus ?? false) {
                      session?.focus.unfocus();
                    } else {
                      session?.focus.requestFocus();
                    }
                  },
                  icon: const Icon(Icons.keyboard_outlined, size: 18),
                ),
            ] else
              PageRefreshButton(
                onPressed: session == null ? null : () => _connect(session),
              ),
          ],
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!compact) ...[
                SizedBox(width: 230, child: _sessionList()),
                VerticalDivider(width: 1, color: hampanelBorder),
              ],
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 12 : 16,
                    0,
                    compact ? 12 : 24,
                    compact ? 4 : 24,
                  ),
                  child: session == null
                      ? const EmptyState(
                          icon: Icons.terminal_outlined,
                          title: '没有会话',
                          message: '点击右上角新建一个终端会话。',
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: Container(
                            decoration: BoxDecoration(
                              color: _theme().background,
                              border: Border.all(color: hampanelBorder),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            padding: const EdgeInsets.all(8),
                            child: TerminalView(
                              session.terminal,
                              key: ValueKey('terminal-${session.id}'),
                              controller: session.controller,
                              focusNode: session.focus,
                              autofocus:
                                  widget.autoConnect &&
                                  !PlatformSupport.isMobile,
                              theme: _theme(),
                              shortcuts: _shortcuts,
                              cursorType: _cursorType,
                              textStyle: TerminalStyle(
                                fontSize: _settings.fontSize,
                                height: _settings.lineHeight,
                                fontFamily: kMonoFamily,
                                fontFamilyFallback: kMonoFallback,
                              ),
                              padding: const EdgeInsets.all(4),
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
        if (compact) ...[
          // Only while the soft keyboard is up; it floats right above the keys.
          if (keyboardOpen) _shortcutBar(session),
          _quickActionBar(session),
          ActionDock(
            actions: [
              ActionDockItem(
                icon: Icons.forum_outlined,
                label: '会话',
                onPressed: _openSessionPicker,
              ),
              ActionDockItem(
                icon: Icons.add_comment_outlined,
                label: '新建',
                onPressed: _addSession,
              ),
              ActionDockItem(
                icon: Icons.tune_outlined,
                label: '外观',
                onPressed: _openStyleSettings,
              ),
              ActionDockItem(
                icon: Icons.keyboard_outlined,
                label: '键盘',
                onPressed: session == null
                    ? null
                    : () {
                        if (session.focus.hasFocus) {
                          session.focus.unfocus();
                        } else {
                          session.focus.requestFocus();
                        }
                      },
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Secondary terminal actions, kept directly above the bottom action dock so
  /// the terminal view keeps the available height.
  Widget _quickActionBar(_TerminalSession? session) {
    return Container(
      decoration: BoxDecoration(
        color: hampanelSurface,
        border: Border(top: BorderSide(color: hampanelBorder)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          _quickAction(
            icon: Icons.content_copy_outlined,
            label: '复制',
            onPressed: session == null ? null : _copy,
          ),
          _quickAction(
            icon: Icons.content_paste_outlined,
            label: '粘贴',
            onPressed: session == null ? null : _paste,
          ),
          _quickAction(
            icon: Icons.clear_all,
            label: '清屏',
            onPressed: session == null
                ? null
                : () => session.terminal.eraseDisplay(),
          ),
          _quickAction(
            icon: Icons.refresh,
            label: '重连',
            onPressed: session == null ? null : () => _connect(session),
          ),
        ],
      ),
    );
  }

  Widget _quickAction({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return Expanded(
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(0, 34),
          visualDensity: VisualDensity.compact,
          textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  void _openSessionPicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: hampanelSurface,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SizedBox(
          height: 420,
          child: SafeArea(
            child: _sessionList(
              onPicked: () => Navigator.of(sheetContext).pop(),
              onChanged: () => setSheetState(() {}),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sessionList({VoidCallback? onPicked, VoidCallback? onChanged}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 6),
          child: Row(
            children: [
              Text(
                '会话',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: hampanelMuted,
                  letterSpacing: 0.6,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '新建会话',
                onPressed: () {
                  _addSession();
                  onPicked?.call();
                },
                icon: const Icon(Icons.add, size: 16),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            itemCount: _sessions.length,
            itemBuilder: (context, index) {
              final session = _sessions[index];
              final selected = session.id == _activeId;
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Material(
                  color: selected ? hampanelSurfaceAlt : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(2),
                    onTap: () {
                      _selectSession(session.id);
                      onPicked?.call();
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 2, 6),
                      child: Row(
                        children: [
                          Icon(
                            session.connected
                                ? Icons.circle
                                : Icons.circle_outlined,
                            size: 9,
                            color: session.connected
                                ? hampanelAccent
                                : hampanelMuted,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  session.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  session.status,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    color: hampanelMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭会话',
                            visualDensity: VisualDensity.compact,
                            onPressed: () async {
                              await _closeSession(session.id);
                              onChanged?.call();
                            },
                            icon: const Icon(Icons.close, size: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _shortcutBar(_TerminalSession? session) {
    final keys = <(String, String)>[
      ('Esc', '\x1b'),
      ('Tab', '\t'),
      ('⌫', '\x7f'),
      ('Ctrl+C', '\x03'),
      ('Ctrl+D', '\x04'),
      ('↑', '\x1b[A'),
      ('↓', '\x1b[B'),
      ('←', '\x1b[D'),
      ('→', '\x1b[C'),
      ('Home', '\x1b[H'),
      ('End', '\x1b[F'),
      ('PgUp', '\x1b[5~'),
      ('PgDn', '\x1b[6~'),
    ];
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final key in keys)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: OutlinedButton(
                onPressed: session == null || !session.connected
                    ? null
                    : () => _send(session, key.$2),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(42, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  textStyle: const TextStyle(fontSize: 11),
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(key.$1),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: OutlinedButton(
              onPressed: _settings.fontSize > TerminalSettings.minFontSize
                  ? () => _adjustFontSize(-1)
                  : null,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(38, 32),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('A-'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: OutlinedButton(
              onPressed: _settings.fontSize < TerminalSettings.maxFontSize
                  ? () => _adjustFontSize(1)
                  : null,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(38, 32),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('A+'),
            ),
          ),
        ],
      ),
    );
  }
}
