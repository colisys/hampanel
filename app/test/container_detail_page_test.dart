import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/api_client.dart';
import 'package:hampanel/features/docker/container_detail_page.dart';
import 'package:material_ui/material_ui.dart';

class _Api implements ApiClient {
  static const containers = '/api/v1/docker/containers';
  final reads = <String>[];
  String? rebuildPath;
  Map<String, dynamic>? rebuildBody;

  @override
  Future<dynamic> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    if (path.endsWith('/networks')) return <String, dynamic>{};
    reads.add(path);
    final rebuilt = path == '$containers/renamed';
    return <String, dynamic>{
      'id': rebuilt ? 'new-id' : 'old-id',
      'name': rebuilt ? 'renamed' : 'original',
      'image': 'nginx',
      'ip': rebuilt ? rebuildBody!['ip'] : '',
      'mac_address': rebuilt ? rebuildBody!['mac_address'] : '',
      'ports': [
        {
          'host_ip': '',
          'host_port': '8080',
          'container_port': '80',
          'protocol': 'tcp',
        },
      ],
      'add_hosts': ['db.local:2001:db8::1'],
      'labels': ['example.role=old=value'],
    };
  }

  @override
  Future<dynamic> postJson(
    String path,
    Object? body, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    rebuildPath = path;
    rebuildBody = body as Map<String, dynamic>;
    return {'ok': true};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('edits existing rows and reloads rebuilt container by name', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _Api();
    await tester.pumpWidget(MaterialApp(
      home: ContainerDetailPage(api: api, containerId: 'old-id'),
    ));
    await tester.pumpAndSettle();

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Finder field(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );

    final network = find.widgetWithText(Tab, '网络');
    await tester.enterText(field('容器名称'), 'renamed');
    await tester.enterText(field('静态 IP 地址'), '192.0.2.10');
    await tester.enterText(field('MAC 地址'), '02:42:00:00:00:10');
    await tap(find.text('8080:80/tcp'));
    expect(find.text('编辑端口映射'), findsOneWidget);
    await tester.enterText(field('主机端口'), '9090');
    await tap(find.text('保存'));

    await tap(find.text('添加').last);
    expect(find.text('添加端口映射'), findsOneWidget);
    await tester.enterText(field('主机 IP'), '2001:db8::2');
    await tester.enterText(field('容器端口'), '81');
    await tap(find.text('保存'));

    await tap(find.widgetWithText(Tab, '主机映射'));
    await tap(find.text('db.local:2001:db8::1'));
    expect(tester.widget<TextField>(field('IP 地址')).controller!.text,
        '2001:db8::1');
    await tester.enterText(field('IP 地址'), '2001:db8::3');
    await tap(find.text('保存'));

    await tap(find.widgetWithText(Tab, '环境'));
    await tap(find.text('example.role'));
    expect(tester.widget<TextField>(field('值')).controller!.text, 'old=value');
    await tester.enterText(field('值'), 'new=value');
    await tap(find.text('保存'));
    await tap(find.text('保存并重建'));
    await tap(find.text('重建'));

    expect(api.rebuildPath, '${_Api.containers}/old-id/recreate');
    expect(api.rebuildBody, containsPair('name', 'renamed'));
    expect(api.rebuildBody, containsPair('ip', '192.0.2.10'));
    expect(api.rebuildBody, containsPair('mac_address', '02:42:00:00:00:10'));
    expect(api.rebuildBody!['ports'], ['9090:80/tcp', '[2001:db8::2]::81/tcp']);
    expect(api.rebuildBody!['add_hosts'], ['db.local:2001:db8::3']);
    expect(api.rebuildBody!['labels'], ['example.role=new=value']);
    expect(api.reads, ['${_Api.containers}/old-id', '${_Api.containers}/renamed']);
    await tap(network);
    expect(tester.widget<TextField>(field('容器名称')).controller!.text, 'renamed');
    expect(tester.widget<TextField>(field('静态 IP 地址')).controller!.text,
        '192.0.2.10');
  });
}
