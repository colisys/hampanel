import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/enrollment.dart';
import '../../ui/theme.dart';
import 'install_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onEnrolled});

  final Future<void> Function(Enrollment enrollment) onEnrolled;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _controller.text = data!.text!;
    }
  }

  Future<void> _connect() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final enrollment = Enrollment.fromText(_controller.text);
      await widget.onEnrolled(enrollment);
    } catch (error) {
      setState(
        () => _error = error.toString().replaceFirst('FormatException: ', ''),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: hampanelAccent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: hampanelAccent.withValues(alpha: 0.4),
                            ),
                          ),
                          child: const Icon(
                            Icons.dns_outlined,
                            color: hampanelAccent,
                          ),
                        ),
                        const SizedBox(width: 14),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Hampanel',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '双向 TLS 服务器面板',
                              style: TextStyle(
                                fontSize: 12,
                                color: hampanelMuted,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 26),
                    const Text(
                      '导入注册凭据',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '将 `hampaneld init` 或 hampanelctl 生成的 enrollment JSON 粘贴到下方。'
                      '凭据包含 CA、客户端证书与私钥，仅保存在本机。',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: hampanelMuted,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _controller,
                      minLines: 8,
                      maxLines: 16,
                      style: monospace,
                      decoration: const InputDecoration(
                        hintText: '{ "endpoint": "203.0.113.10:8443", "ca_pem": "...", ... }',
                        alignLabelWithHint: true,
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: const TextStyle(
                          color: hampanelDanger,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: _paste,
                          icon: const Icon(Icons.content_paste, size: 16),
                          label: const Text('从剪贴板粘贴'),
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: _busy ? null : _connect,
                          icon: _busy
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.lock_open, size: 17),
                          label: const Text('建立连接'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Divider(height: 1),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '还没有可管理的主机？可以直接通过 SSH 安装 hampaneld，'
                            '选择发布二进制或从头构建。',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: hampanelMuted,
                              height: 1.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => InstallPage(
                                      onEnrolled: widget.onEnrolled,
                                    ),
                                  ),
                                ),
                          icon: const Icon(Icons.terminal, size: 16),
                          label: const Text('通过 SSH 安装'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
