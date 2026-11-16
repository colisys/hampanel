import 'package:material_ui/material_ui.dart';

import '../core/enrollment.dart';
import '../core/format.dart';
import 'theme.dart';
import 'widgets.dart';

/// Shows the certificates carried by an enrollment bundle and requires the
/// operator to confirm them out of band before the client trusts the host.
Future<bool> confirmEnrollmentTrust(
  BuildContext context,
  Enrollment enrollment,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('核对服务端证书指纹'),
      content: DialogBody(
        maxWidth: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '客户端只信任该 CA 签发的服务端证书。请通过带外渠道（例如服务器上的 '
              '`hampaneld show` 或控制台输出）核对下面的指纹，再建立连接。',
              style: TextStyle(fontSize: 12, color: hampanelMuted, height: 1.6),
            ),
            const SizedBox(height: 14),
            _TrustField(label: 'Endpoint', value: enrollment.endpoint),
            _TrustField(label: '客户端 CN', value: enrollment.clientCn),
            _TrustField(
              label: 'CA SHA-256',
              value: formatFingerprint(enrollment.caSha256),
              mono: true,
            ),
            _TrustField(
              label: '服务端 SHA-256',
              value: formatFingerprint(enrollment.serverSha256),
              mono: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('我已核对，继续'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

class _TrustField extends StatelessWidget {
  const _TrustField({
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 10.5, color: hampanelMuted)),
          const SizedBox(height: 2),
          SelectableText(
            value.isEmpty ? '未提供' : value,
            style: mono
                ? monospace.copyWith(fontSize: 11)
                : const TextStyle(fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}
