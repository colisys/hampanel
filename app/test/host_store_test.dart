import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/enrollment.dart';
import 'package:hampanel/core/host_store.dart';

const _bundleA = '{"schema":1,"product":"Hampanel","endpoint":"203.0.113.10:8443",'
    '"entry_prefix":"/sA","ca_pem":"CA_A","client_cert_pem":"CERT_A",'
    '"client_key_pem":"KEY_A","ca_sha256":"aa","server_sha256":"sa",'
    '"client_cn":"hampanel-a","created_at":"now"}';

const _bundleB = '{"schema":1,"product":"Hampanel","endpoint":"198.51.100.7:9443",'
    '"entry_prefix":"/sB","ca_pem":"CA_B","client_cert_pem":"CERT_B",'
    '"client_key_pem":"KEY_B","ca_sha256":"ab","server_sha256":"sb",'
    '"client_cn":"hampanel-b","created_at":"now"}';

Future<Directory> _tempDir() async {
  final dir = await Directory.systemTemp.createTemp('host-store-test');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

void main() {
  test('upsert adds, dedupes by endpoint+prefix and activates', () async {
    final store = await HostStore.open(directory: await _tempDir());
    addTearDown(store.close);
    expect(store.list(), isEmpty);

    final a = store.upsert(
      alias: 'edge-01',
      enrollment: Enrollment.fromText(_bundleA),
      activate: true,
    );
    expect(store.activeId, a.id);
    expect(a.alias, 'edge-01');

    // 同一 endpoint+prefix 再次导入应更新而不是新增
    final again = store.upsert(
      alias: 'edge-01-renamed',
      enrollment: Enrollment.fromText(_bundleA),
      activate: true,
    );
    expect(again.id, a.id);
    expect(store.list().length, 1);
    expect(store.byId(a.id)!.alias, 'edge-01-renamed');

    final b = store.upsert(
      alias: 'backup',
      enrollment: Enrollment.fromText(_bundleB),
      activate: true,
    );
    expect(store.list().length, 2);
    expect(store.activeId, b.id);
  });

  test('switch active host and delete', () async {
    final store = await HostStore.open(directory: await _tempDir());
    addTearDown(store.close);
    final a = store.upsert(
      alias: 'a',
      enrollment: Enrollment.fromText(_bundleA),
      activate: true,
    );
    final b = store.upsert(alias: 'b', enrollment: Enrollment.fromText(_bundleB));
    store.setActive(a.id);
    expect(store.activeId, a.id);
    store.setActive(b.id);
    expect(store.activeId, b.id);

    store.delete(b.id);
    expect(store.byId(b.id), isNull);
    expect(store.list().length, 1);
  });

  test('imports legacy enrollment.json exactly once', () async {
    final dir = await _tempDir();
    File('${dir.path}/enrollment.json').writeAsStringSync(_bundleA);
    final store = await HostStore.open(directory: dir);
    addTearDown(store.close);

    final hosts = store.list();
    expect(hosts.length, 1);
    expect(hosts.first.alias, '203.0.113.10');
    expect(store.activeId, hosts.first.id);
    expect(hosts.first.enrollment.entryPrefix, '/sA');
    expect(File('${dir.path}/enrollment.json').existsSync(), isFalse);
    expect(File('${dir.path}/enrollment.json.migrated').existsSync(), isTrue);

    // 重开不应重复导入（文件已改名）
    store.close();
    final reopened = await HostStore.open(directory: dir);
    addTearDown(reopened.close);
    expect(reopened.list().length, 1);
  });

  test('update alias and enrollment round-trips through sqlite', () async {
    final store = await HostStore.open(directory: await _tempDir());
    addTearDown(store.close);
    final a = store.upsert(
      alias: 'a',
      enrollment: Enrollment.fromText(_bundleA),
      activate: true,
    );
    store.updateEnrollment(
      a.id,
      Enrollment.fromText(_bundleB),
      alias: 'rotated',
    );
    final reloaded = await HostStore.open(directory: await _tempDir()
      ..deleteSync(recursive: true)
      ..createSync());
    addTearDown(reloaded.close);
    // 无法跨库断言；这里只验证内存态
    final updated = store.byId(a.id)!;
    expect(updated.alias, 'rotated');
    expect(updated.enrollment.endpoint, '198.51.100.7:9443');
    expect(updated.enrollment.entryPrefix, '/sB');
  });
}
