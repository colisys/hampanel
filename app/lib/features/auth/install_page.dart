import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/enrollment.dart';
import '../../core/ssh_installer.dart';
import '../../ui/theme.dart';

/// Onboarding wizard: install hampaneld on a remote host over SSH, choosing
/// between a published release binary and a source build.
class InstallPage extends StatefulWidget {
  const InstallPage({super.key, required this.onEnrolled});

  final Future<void> Function(Enrollment enrollment, {String? alias}) onEnrolled;

  @override
  State<InstallPage> createState() => _InstallPageState();
}

class _InstallPageState extends State<InstallPage> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController(text: 'root');
  final _password = TextEditingController();
  final _keyPath = TextEditingController();
  final _keyPassphrase = TextEditingController();
  final _endpoint = TextEditingController();
  final _alias = TextEditingController();
  final _panelPort = TextEditingController();
  final _sourceRef = TextEditingController(text: 'nightly');
  final _mirrorCustom = TextEditingController();
  final _githubMirror = TextEditingController();
  final _logScroll = ScrollController();

  String _auth = 'password';
  String _mode = 'binary';
  String _channel = 'stable';
  String _mirror = '';
  bool _busy = false;
  String? _error;
  final List<String> _log = [];

  @override
  void dispose() {
    for (final controller in [
      _host,
      _alias,
      _port,
      _user,
      _password,
      _keyPath,
      _keyPassphrase,
      _endpoint,
      _panelPort,
      _sourceRef,
      _mirrorCustom,
      _githubMirror,
    ]) {
      controller.dispose();
    }
    _logScroll.dispose();
    super.dispose();
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_logScroll.hasClients) return;
      _logScroll.animateTo(
        _logScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _install() async {
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = '请填写主机地址');
      return;
    }
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = 'SSH 端口无效');
      return;
    }
    final panelPort = _panelPort.text.trim().isEmpty
        ? null
        : int.tryParse(_panelPort.text.trim());
    if (_panelPort.text.trim().isNotEmpty && panelPort == null) {
      setState(() => _error = '面板端口无效');
      return;
    }
    if (_user.text.trim().isEmpty) {
      setState(() => _error = '请填写 SSH 用户名');
      return;
    }
    if (_auth == 'password' && _password.text.isEmpty) {
      setState(() => _error = '请填写 SSH 密码');
      return;
    }
    if (_auth == 'key' && _keyPath.text.trim().isEmpty) {
      setState(() => _error = '请填写私钥路径');
      return;
    }
    final mirror = _mirror == 'custom'
        ? 'custom:${_mirrorCustom.text.trim()}'
        : _mirror;
    if (_mirror == 'custom' && _mirrorCustom.text.trim().isEmpty) {
      setState(() => _error = '请填写自定义镜像地址');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _log.clear();
    });

    try {
      final enrollment = await SshInstaller().install(
        SshInstallRequest(
          host: host,
          port: port,
          username: _user.text.trim(),
          password: _auth == 'password' ? _password.text : null,
          privateKeyPath: _auth == 'key' ? _keyPath.text.trim() : null,
          privateKeyPassphrase: _auth == 'key' && _keyPassphrase.text.isNotEmpty
              ? _keyPassphrase.text
              : null,
          endpoint: _endpoint.text.trim(),
          mode: _mode,
          channel: _channel,
          sourceRef: _sourceRef.text.trim().isEmpty
              ? 'nightly'
              : _sourceRef.text.trim(),
          panelPort: panelPort,
          mirror: mirror,
          githubMirror: _githubMirror.text.trim(),
          alias: _alias.text.trim(),
        ),
        onLog: _append,
      );
      _append('安装完成，正在保存注册凭据 ...');
      final alias = _alias.text.trim();
      await widget.onEnrolled(enrollment, alias: alias.isEmpty ? null : alias);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      _append('错误：${describeError(error)}');
      setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pasteKeyPath() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) _keyPath.text = data!.text!.trim();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('通过 SSH 安装 Hampanel')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '在没有可用面板时，可以通过 SSH 在远程 Linux 或 Windows 主机上安装 hampaneld。'
                  '选择发布二进制会自动启用每日更新检查；源码构建不会启用。',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: hampanelMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 18),
                _section('01', 'SSH 连接', [
                  _row([
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _host,
                        decoration: const InputDecoration(
                          labelText: '主机',
                          hintText: '203.0.113.10 或 panel.example.com',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _port,
                        decoration: const InputDecoration(labelText: 'SSH 端口'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 170,
                      child: TextField(
                        controller: _user,
                        decoration: const InputDecoration(labelText: '用户名'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _auth,
                    decoration: const InputDecoration(labelText: '认证方式'),
                    items: const [
                      DropdownMenuItem(value: 'password', child: Text('密码')),
                      DropdownMenuItem(value: 'key', child: Text('私钥文件')),
                    ],
                    onChanged: (value) =>
                        setState(() => _auth = value ?? 'password'),
                  ),
                  const SizedBox(height: 10),
                  if (_auth == 'password')
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'SSH 密码'),
                    )
                  else ...[
                    _row([
                      Expanded(
                        child: TextField(
                          controller: _keyPath,
                          decoration: const InputDecoration(
                            labelText: '私钥路径',
                            hintText: '/home/me/.ssh/id_ed25519',
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _pasteKeyPath,
                        tooltip: '从剪贴板粘贴',
                        icon: const Icon(Icons.content_paste, size: 18),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _keyPassphrase,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '私钥口令（可选）'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    '非 root 用户需要配置免密 sudo。私钥仅在本机读取，不会上传。',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                ]),
                const SizedBox(height: 14),
                _section('02', '安装方式', [
                  DropdownButtonFormField<String>(
                    initialValue: _mode,
                    decoration: const InputDecoration(labelText: '安装类型'),
                    items: const [
                      DropdownMenuItem(
                        value: 'binary',
                        child: Text('发布二进制（自动更新检查）'),
                      ),
                      DropdownMenuItem(
                        value: 'source',
                        child: Text('从头构建（不启用更新检查）'),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _mode = value ?? 'binary'),
                  ),
                  const SizedBox(height: 10),
                  if (_mode == 'binary')
                    DropdownButtonFormField<String>(
                      initialValue: _channel,
                      decoration: const InputDecoration(labelText: '发布通道'),
                      items: const [
                        DropdownMenuItem(value: 'stable', child: Text('正式版')),
                        DropdownMenuItem(
                          value: 'nightly',
                          child: Text('nightly'),
                        ),
                      ],
                      onChanged: (value) =>
                          setState(() => _channel = value ?? 'stable'),
                    )
                  else
                    TextField(
                      controller: _sourceRef,
                      decoration: const InputDecoration(
                        labelText: '源码分支或标签',
                        hintText: 'nightly',
                      ),
                    ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _mirror,
                    decoration: const InputDecoration(
                      labelText: '软件源镜像（Linux 依赖）',
                    ),
                    items: const [
                      DropdownMenuItem(value: '', child: Text('使用系统默认源')),
                      DropdownMenuItem(
                        value: 'aliyun',
                        child: Text('阿里云 mirrors.aliyun.com'),
                      ),
                      DropdownMenuItem(
                        value: 'tencent',
                        child: Text('腾讯云 mirrors.cloud.tencent.com'),
                      ),
                      DropdownMenuItem(
                        value: 'ustc',
                        child: Text('中科大 mirrors.ustc.edu.cn'),
                      ),
                      DropdownMenuItem(
                        value: 'tuna',
                        child: Text('清华 mirrors.tuna.tsinghua.edu.cn'),
                      ),
                      DropdownMenuItem(
                        value: 'custom',
                        child: Text('自定义镜像地址'),
                      ),
                    ],
                    onChanged: (value) => setState(() => _mirror = value ?? ''),
                  ),
                  if (_mirror == 'custom') ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _mirrorCustom,
                      decoration: const InputDecoration(
                        labelText: '镜像域名或 URL',
                        hintText: 'https://mirrors.example.com',
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    '镜像仅用于 Linux 目标机安装依赖包（apt/apk）；Windows 目标忽略此项。',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _githubMirror,
                    decoration: const InputDecoration(
                      labelText: 'GitHub 镜像（可选）',
                      hintText: 'https://ghfast.top 或 https://gitclone.com/github.com',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '用于下载 release 与源码归档。直接在完整 GitHub 地址前拼接镜像前缀。',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                  const SizedBox(height: 10),
                  _row([
                    Expanded(
                      child: TextField(
                        controller: _endpoint,
                        decoration: InputDecoration(
                          labelText: '面板地址（可选）',
                          hintText:
                              '留空则使用 SSH 主机：${_host.text.isEmpty ? 'host' : _host.text}',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 140,
                      child: TextField(
                        controller: _panelPort,
                        decoration: const InputDecoration(
                          labelText: '面板端口（可选）',
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    '面板地址用于证书 SAN。通过 NAT 或域名访问时请填写公网地址；端口留空会自动选择。',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                ]),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: hampanelDanger,
                      fontSize: 12.5,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _install,
                      icon: _busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.rocket_launch_outlined, size: 17),
                      label: Text(_busy ? '安装中…' : '开始安装'),
                    ),
                    const SizedBox(width: 12),
                    if (_busy)
                      Text(
                        '源码构建可能需要几分钟，请保持页面打开',
                        style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                      ),
                  ],
                ),
                if (_log.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Container(
                    height: 260,
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B1116),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: hampanelInk, width: 2),
                    ),
                    child: Scrollbar(
                      controller: _logScroll,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _logScroll,
                        child: SelectableText(
                          _log.join('\n'),
                          style: monospace.copyWith(
                            fontSize: 11.5,
                            color: const Color(0xFFE8E0CE),
                            height: 1.45,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(String index, String title, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(boxShadow: mangaShadow),
      child: Container(
        decoration: BoxDecoration(
          color: hampanelSurface,
          border: Border.all(color: hampanelInk, width: 2),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  index,
                  style: mangaKicker.copyWith(
                    color: hampanelAccent,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: 8),
                Container(width: 5, height: 16, color: hampanelAccent),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _row(List<Widget> children) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: children);
}
