import 'package:material_ui/material_ui.dart';

import '../../core/models/site.dart';

class CronTlsFields extends StatefulWidget {
  const CronTlsFields({
    super.key,
    required this.certificate,
    required this.privateKeyPath,
    required this.sites,
    required this.onChanged,
  });

  final String certificate;
  final String privateKeyPath;
  final List<Site> sites;
  final void Function(String certificate, String keyPath) onChanged;

  @override
  State<CronTlsFields> createState() => _CronTlsFieldsState();
}

class _CronTlsFieldsState extends State<CronTlsFields> {
  int revision = 0;

  @override
  Widget build(BuildContext context) {
    final candidates = widget.sites.where(
      (s) => isWebhookTlsPath(s.tls.certificate) && isWebhookTlsPath(s.tls.key),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '内部 Cron 必须使用 HTTPS。只填 Nginx 可读的服务器绝对路径，不要粘贴 PEM 内容。证书须覆盖回调域名。',
        ),
        if (candidates.isNotEmpty)
          PopupMenuButton<Site>(
            tooltip: '选择已有站点证书',
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('选择已有站点证书'),
            ),
            itemBuilder: (_) => [
              for (final site in candidates)
                PopupMenuItem(value: site, child: Text(site.name)),
            ],
            onSelected: (site) {
              setState(() => revision++);
              widget.onChanged(site.tls.certificate, site.tls.key);
            },
          ),
        TextFormField(
          key: ValueKey('cert-$revision'),
          initialValue: widget.certificate,
          decoration: const InputDecoration(labelText: '证书链路径'),
          onChanged: (value) => widget.onChanged(value, widget.privateKeyPath),
        ),
        TextFormField(
          key: ValueKey('key-$revision'),
          initialValue: widget.privateKeyPath,
          enableSuggestions: false,
          autocorrect: false,
          decoration: const InputDecoration(labelText: '私钥路径'),
          onChanged: (value) => widget.onChanged(widget.certificate, value),
        ),
        const Text('需要上传证书？先创建外部 Webhook，再在详情上传证书链和私钥，最后切换到内部计划任务。'),
      ],
    );
  }
}
