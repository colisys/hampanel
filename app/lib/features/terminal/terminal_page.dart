import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import '../../core/api_client.dart';
import '../../core/platform_support.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, this.autoConnect = true});

  /// IndexedStack 会构建所有隐藏页；只有当前激活标签才允许自动建连。
  final bool autoConnect;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final FocusNode _terminalFocus = FocusNode();
  late final Terminal _terminal;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  String _status = '正在连接';
  bool _connected = false;
  double _fontSize = 13;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 8000);
    _terminal.onOutput = (data) {
      if (_connected) _socket?.add(data);
    };
    _terminal.onResize = (width, height, _, _) {
      if (_connected && _socket?.readyState == WebSocket.open) {
        _socket?.add(
          jsonEncode({'type': 'resize', 'cols': width, 'rows': height}),
        );
      }
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 仅在页面实际可见（所在标签页处于激活状态）时建立会话，
      // 避免 IndexedStack 隐藏页也发起连接。
      if (widget.autoConnect && !_connectStarted) {
        _connectStarted = true;
        _connect();
      }
    });
  }

  bool _connectStarted = false;

  @override
  void didUpdateWidget(covariant TerminalPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoConnect && !oldWidget.autoConnect && !_connectStarted) {
      _connectStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_connected) _connect();
      });
    }
  }

  @override
  void dispose() {
    _terminalFocus.dispose();
    _subscription?.cancel();
    _socket?.close();
    super.dispose();
  }

  Future<void> _connect() async {
    try {
      _subscription?.cancel();
      _socket?.close();
      setState(() {
        _status = '正在建立 mTLS 终端会话';
        _connected = false;
      });
      final socket = await PanelScope.of(context).api
          .openTerminal(cols: _terminal.viewWidth, rows: _terminal.viewHeight);
      if (!mounted) {
        socket.close();
        return;
      }
      _socket = socket;
      _connected = true;
      setState(() => _status = '已连接');
      _subscription = socket.listen(
        (data) {
          if (data is String) {
            _terminal.write(data);
          } else if (data is List<int>) {
            _terminal.write(utf8.decode(data, allowMalformed: true));
          }
        },
        onDone: () {
          if (!mounted) return;
          setState(() {
            _connected = false;
            _status = '会话已断开';
          });
          _terminal.write('\r\n\x1b[33m[hampanel] 会话已断开\x1b[0m\r\n');
        },
        onError: (Object error) {
          if (!mounted) return;
          setState(() {
            _connected = false;
            _status = describeError(error);
          });
        },
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _connected = false;
        _status = describeError(error);
      });
      _terminal.write(
        '\r\n\x1b[31m[hampanel] ${describeError(error)}\x1b[0m\r\n',
      );
    }
  }

  void _send(String data) {
    if (!_connected || _socket?.readyState != WebSocket.open) return;
    _socket?.add(data);
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    return Column(
      children: [
        PageHeader(
          title: '终端',
          subtitle: compact ? null : 'PTY 会话通过 WebSocket + mTLS 传输',
          actions: [
            StatusPill(text: _status, good: _connected),
            const SizedBox(width: 6),
            if (PlatformSupport.isMobile)
              IconButton(
                tooltip: '切换键盘',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  if (_terminalFocus.hasFocus) {
                    _terminalFocus.unfocus();
                  } else {
                    _terminalFocus.requestFocus();
                  }
                },
                icon: const Icon(Icons.keyboard_outlined, size: 18),
              ),
            if (compact)
              IconButton(
                tooltip: '重新连接',
                visualDensity: VisualDensity.compact,
                onPressed: _connect,
                icon: const Icon(Icons.refresh, size: 18),
              )
            else
              OutlinedButton.icon(
                onPressed: _connect,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重新连接'),
              ),
          ],
        ),
        if (compact) _shortcutBar(),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 12 : 24,
              0,
              compact ? 12 : 24,
              compact ? 12 : 24,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF070B0E),
                  border: Border.all(color: hampanelBorder),
                  borderRadius: BorderRadius.circular(3),
                ),
                padding: const EdgeInsets.all(8),
                child: TerminalView(
                  _terminal,
                  focusNode: _terminalFocus,
                  autofocus: !PlatformSupport.isMobile,
                  textStyle: TerminalStyle(fontSize: _fontSize),
                  padding: const EdgeInsets.all(4),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _shortcutBar() {
    final keys = <(String, String)>[
      ('Esc', '\x1b'),
      ('Tab', '\t'),
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
                onPressed: _connected ? () => _send(key.$2) : null,
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
              onPressed: _fontSize > 10
                  ? () => setState(() => _fontSize -= 1)
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
              onPressed: _fontSize < 22
                  ? () => setState(() => _fontSize += 1)
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
