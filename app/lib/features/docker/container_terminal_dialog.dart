import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import '../../core/api_client.dart';
import '../../core/models/docker.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class ContainerTerminalDialog extends StatefulWidget {
  const ContainerTerminalDialog({super.key, required this.container});

  final DockerContainer container;

  @override
  State<ContainerTerminalDialog> createState() =>
      _ContainerTerminalDialogState();
}

class _ContainerTerminalDialogState extends State<ContainerTerminalDialog> {
  final _focus = FocusNode();
  late final Terminal _terminal;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  bool _connected = false;
  String _status = '正在连接';

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
      if (mounted) _connect();
    });
  }

  Future<void> _connect() async {
    try {
      _subscription?.cancel();
      _socket?.close();
      setState(() {
        _status = '正在建立 mTLS 会话';
        _connected = false;
      });
      final socket = await PanelScope.of(context).api.openSocket(
        '/api/v1/docker/containers/${widget.container.id}/terminal/ws',
        {
          'cols': '${_terminal.viewWidth}',
          'rows': '${_terminal.viewHeight}',
          'shell': '/bin/sh',
        },
      );
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
      _terminal.write('\r\n\x1b[31m[hampanel] ${describeError(error)}\x1b[0m\r\n');
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _subscription?.cancel();
    _socket?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('终端 · ${widget.container.name}'),
      content: DialogBody(
        maxWidth: 920,
        maxHeight: 600,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _status,
                  style: TextStyle(fontSize: 11, color: hampanelMuted),
                ),
                const Spacer(),
                Text(
                  _connected ? 'Ctrl+D 退出' : '',
                  style: TextStyle(fontSize: 11, color: hampanelMuted),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
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
                    focusNode: _focus,
                    autofocus: true,
                    padding: const EdgeInsets.all(4),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _connect,
          child: const Text('重连'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
