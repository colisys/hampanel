import 'package:flutter_test/flutter_test.dart';

import 'package:hampanel/core/file_results.dart';
import 'package:hampanel/core/models/file_entry.dart';
import 'package:hampanel/core/models/docker.dart';

void main() {
  test('truncated and binary content cannot be edited', () {
    for (final json in [
      {'truncated': true, 'encoding': 'utf8', 'content': 'partial'},
      {'truncated': false, 'encoding': 'base64'},
    ]) {
      expect(FileContent.fromJson(json).requireEditable, throwsStateError);
    }
    expect(FileContent.fromJson({'content': 'complete'}).requireEditable,
        returnsNormally);
  });

  test('delete requires explicit success for every requested path', () {
    expect(() => requireDeleted({
      'results': [
        {'path': '/a', 'ok': true},
        {'path': '/b', 'ok': false, 'message': 'PermissionDenied'},
      ],
    }, ['/a', '/b']), throwsStateError);
    expect(() => requireDeleted({'results': []}, ['/a']), throwsStateError);
    expect(() => requireDeleted({}, ['/a']), throwsStateError);
    expect(() => requireDeleted({
      'results': [
        {'path': '/a', 'ok': true},
      ],
    }, ['/a']), returnsNormally);
  });

  test('overview accepts failed and legacy error with failed precedence', () {
    for (final counts in [
      {'failed': 3},
      {'error': 3},
      {'failed': 3, 'error': 9},
    ]) {
      expect(DockerOverview.fromJson({'containers': counts}).failed, 3);
    }
    expect(DockerOverview.fromJson({}).failed, 0);
  });
}
