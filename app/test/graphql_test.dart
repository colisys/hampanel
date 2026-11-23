import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/features/graphql/graphql_client.dart';
import 'package:hampanel/features/graphql/graphql_page.dart';
import 'package:re_editor/re_editor.dart' as re;

void main() {
  const endpoint = 'https://example.test/graphql';
  const query = r'query($id: ID!) { node(id: $id) { id } }';

  test('sends the query, typed variables and auth header', () async {
    final client = GraphqlClient(transport: (uri, headers, body) async {
      expect(uri.toString(), endpoint);
      expect(headers['content-type'], 'application/json');
      expect(headers['x-test-auth'], 'example');
      expect(jsonDecode(body), {'query': query, 'variables': {'id': 42}});
      return (status: 200, body: '{}');
    });
    final result = await client.execute(endpoint: endpoint, query: query,
      variables: '{"id":42}', headers: '{"X-Test-Auth":"example"}' );
    expect(result.status, 200);
  });

  test('invalid inputs never reach transport', () async {
    final client = GraphqlClient(transport: (_, _, _) async => fail('Unexpected request'));
    for (final (url, document, variables, headers) in [
      ('file:///local', query, '', ''),
      (endpoint, ' ', '', ''),
      (endpoint, query, '[]', ''),
      (endpoint, query, '', '{'),
      (endpoint, query, '', '{"x-test-auth":42}'),
    ]) {
      await expectLater(client.execute(endpoint: url, query: document,
        variables: variables, headers: headers), throwsFormatException);
    }
  });

  testWidgets('registered connection executes only the read-only catalog document', (tester) async {
    String? sent;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: GraphqlPage(
      catalogQuery: '{ tables }', executeCatalog: (query) async {
        sent = query;
        return {'data': {'tables': ['orders']}};
      },
    ))));
    expect(sent, isNull);
    expect(find.byType(re.CodeEditor), findsOneWidget);
    expect(find.text('HTTP(S) 端点'), findsNothing);
    await tester.tap(find.text('执行查询'));
    await tester.pumpAndSettle();
    expect(sent, '{ tables }');
    expect(tester.widget<SelectableText>(find.byType(SelectableText)).data, contains('orders'));
  });

  testWidgets('only submits on demand and displays the full response', (tester) async {
    var calls = 0;
    const payload = '{"data":{"node":null},"errors":[{"message":"Denied"}]}';
    final client = GraphqlClient(transport: (_, _, body) async {
      calls++;
      expect(jsonDecode(body), {'query': query});
      return (status: 403, body: payload);
    });
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: GraphqlPage(client: client))),
    );
    // The endpoint is the only plain TextField; the query and the two JSON
    // blocks are code editors now, so they are typed into via their editors.
    await tester.enterText(find.byType(TextField).at(0), endpoint);
    // The query and the two JSON blocks are code editors; drive them through
    // the editor's own controller, the way code_editor_test does.
    final editors = tester
        .widgetList<re.CodeEditor>(find.byType(re.CodeEditor))
        .toList();
    expect(editors, hasLength(3));
    editors.first.controller!.text = query;
    await tester.pump();
    expect(calls, 0);
    // The request card is taller than the default 600px test viewport, so the
    // button has to be scrolled into view before tapping.
    await tester.ensureVisible(find.text('执行查询'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('执行查询'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('HTTP 403'), findsOneWidget);
    expect(
      jsonDecode(tester.widget<SelectableText>(find.byType(SelectableText)).data!),
      jsonDecode(payload),
    );
  });
}
