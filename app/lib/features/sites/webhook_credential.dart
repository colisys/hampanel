import 'package:material_ui/material_ui.dart';

bool hasWebhookCredential(Map<String, dynamic> response) =>
    response['webhook_url'] is String &&
    (response['webhook_url'] as String).isNotEmpty &&
    response['webhook_token'] is String &&
    (response['webhook_token'] as String).isNotEmpty;

/// Only response fields explicitly returned by the daemon are shown; never
/// reconstruct a credential-bearing URL from site metadata.
Future<void> showWebhookCredential(
  BuildContext context,
  Map<String, dynamic> response,
) async {
  final url = response['webhook_url'];
  final token = response['webhook_token'];
  if ((url is! String || url.isEmpty) && (token is! String || token.isEmpty)) {
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Webhook 凭据（仅显示一次）'),
      content: SelectableText(
        '${url is String && url.isNotEmpty ? 'URL: $url\n' : ''}'
        '${token is String && token.isNotEmpty ? 'Token: $token\n' : ''}'
        '请立即安全保存。含 token 的 URL 是凭据，请勿公开、截图或写入日志。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('已保存'),
        ),
      ],
    ),
  );
}
