import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/enrollment.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'install_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onEnrolled});

  final Future<void> Function(Enrollment enrollment, {String? alias}) onEnrolled;

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
      body: Stack(
        children: [
          Positioned.fill(child: Halftone(opacity: 0.10, spacing: 16)),
          Positioned(
            right: -170,
            top: -190,
            child: Container(
              width: 480,
              height: 480,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hampanelAccent.withValues(alpha: 0.05),
                border: Border.all(color: hampanelAccent, width: 3),
              ),
            ),
          ),
          Positioned(
            left: 28,
            top: 22,
            child: Text(
              'HAMPANEL / MANGA CONSOLE',
              style: mangaKicker.copyWith(color: hampanelInk),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 52,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: Container(
                    decoration: BoxDecoration(
                      color: hampanelSurface,
                      border: Border.all(color: hampanelInk, width: 2.5),
                      boxShadow: mangaShadow,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(34),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 60,
                                height: 60,
                                color: hampanelInk,
                                child: Icon(
                                  Icons.dns_outlined,
                                  color: hampanelSurface,
                                  size: 32,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'HAMPANEL',
                                      style: TextStyle(
                                        fontSize: 38,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 4,
                                        height: 0.95,
                                        color: hampanelInk,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      '双向 TLS 服务器面板 / BI-DIRECTIONAL TLS CONSOLE',
                                      style: mangaKicker.copyWith(
                                        color: hampanelMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: hampanelInk,
                                    width: 1.5,
                                  ),
                                ),
                                child: Text(
                                  'PANEL 01',
                                  style: mangaKicker.copyWith(
                                    color: hampanelInk,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          Container(
                            width: 44,
                            height: 3,
                            color: hampanelAccent,
                          ),
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Text(
                                '01',
                                style: mangaKicker.copyWith(
                                  color: hampanelAccent,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Text(
                                '导入注册凭据',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.3,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '将 `hampaneld init` 或 hampanelctl 生成的 enrollment JSON 粘贴到下方。'
                            '凭据包含 CA、客户端证书与私钥，仅保存在本机。',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: hampanelMuted,
                              height: 1.7,
                            ),
                          ),
                          const SizedBox(height: 18),
                          Text(
                            'ENROLLMENT JSON',
                            style: mangaKicker.copyWith(color: hampanelInk),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _controller,
                            minLines: 8,
                            maxLines: 16,
                            style: monospace,
                            decoration: InputDecoration(
                              hintStyle: monospace.copyWith(
                                color: hampanelMuted,
                              ),
                              hintText:
                                  '{ "endpoint": "203.0.113.10:8443", "ca_pem": "...", ... }',
                              alignLabelWithHint: true,
                            ),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.error_outline,
                                  size: 16,
                                  color: hampanelDanger,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _error!,
                                    style: TextStyle(
                                      color: hampanelDanger,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      height: 1.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              TextButton.icon(
                                onPressed: _busy ? null : _paste,
                                icon: const Icon(
                                  Icons.content_paste,
                                  size: 16,
                                ),
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
                          const SizedBox(height: 18),
                          const Divider(height: 1),
                          const SizedBox(height: 18),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '还没有可管理的主机？可以直接通过 SSH 安装 hampaneld，'
                                  '选择发布二进制或从头构建。',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: hampanelMuted,
                                    height: 1.6,
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
          ),
        ],
      ),
    );
  }
}
