import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_react_embed/flutter_react_embed.dart';
import 'package:flutter_react_embed_example/main.dart';
import 'package:flutter_react_embed_example/react_app_manifest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// End-to-end checks against the open-source React dashboard installed by
/// tool/setup_test_react.sh. Skipped when no bundle is installed.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final bool skip = !reactAppManifest.available;

  testWidgets('dashboard boots with a verified bundle and reports routes', (WidgetTester tester) async {
    final Completer<ReactViewController> created = Completer<ReactViewController>();
    final List<ReactBridgeEvent> events = <ReactBridgeEvent>[];
    final List<ReactEmbedException> errors = <ReactEmbedException>[];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReactView(
          configuration: ReactViewConfiguration(
            engine: ReactEngineConfig(
              engine: ReactEngineKind.web,
              bundle: reactAppManifest.bundle,
              bundleSha256: reactAppManifest.indexSha256,
            ),
            moduleName: '#/dashboard',
          ),
          onViewCreated: (ReactViewController c) {
            c.events().listen(events.add);
            if (!created.isCompleted) created.complete(c);
          },
          onError: (ReactEmbedException e, StackTrace _) => errors.add(e),
        ),
      ),
    ));
    final ReactViewController controller = await _pumpUntil(tester, created.future);

    // The shim's readiness frame (replayed to the first listener) and the
    // mount acknowledgement carrying our initial route.
    await _pumpUntil(tester, _waitFor(events, (ReactBridgeEvent e) => e.name == 'mounted'));
    expect(events.first.name, 'hello');
    await _pumpUntil(tester, _waitFor(events, (ReactBridgeEvent e) => e.name == 'loaded'));

    final Map<String, Object?> state = await _pumpUntil(tester, controller.invoke<Map<String, Object?>>('getState'));
    expect(state['hash'], '#/dashboard');
    expect(state['title'], contains('CoreUI'));

    // Navigation driven from Dart surfaces as a `route` event from React Router.
    await _pumpUntil(tester, controller.invoke<Object?>('navigate', params: <String, Object?>{'path': '#/charts'}));
    final ReactBridgeEvent route = await _pumpUntil(
      tester,
      _waitFor(events, (ReactBridgeEvent e) => e.name == 'route' && (e.data! as Map<String, Object?>)['hash'] == '#/charts'),
    );
    expect((route.data! as Map<String, Object?>)['trigger'], anyOf('popstate', 'hashchange'));

    await expectLater(
      controller.invoke<Object?>('navigate', params: <String, Object?>{}),
      throwsA(isA<ReactRpcException>().having((ReactRpcException e) => e.code, 'code', JsonRpcErrorCode.invalidParams)),
    );
    expect(errors, isEmpty);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }, skip: skip);

  testWidgets('example app switches surfaces and logs JS messages', (WidgetTester tester) async {
    await tester.pumpWidget(const EmbedLabApp());

    // Dashboard first: wait until the log shows the shim's hello.
    await _pumpUntilFound(tester, find.textContaining('hello {'));
    await _pumpUntilFound(tester, find.textContaining('mounted {'));

    await tester.tap(find.text('Charts'));
    await _pumpUntilFound(tester, find.textContaining('"hash":"#/charts"'));

    // Switch to the internal state view through the dropdown.
    await tester.tap(find.text(EmbeddedSurface.reactDashboard.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(EmbeddedSurface.internalState.label).last);
    await _pumpUntilFound(tester, find.textContaining('"moduleName":"/state"'));

    await tester.tap(find.text('count +1'));
    await _pumpUntilFound(tester, find.textContaining(RegExp(r'propsApplied \{.*"count":1\b')));

    // Back to the dashboard: it was retained by cacheKey, so it reattaches.
    await tester.tap(find.text(EmbeddedSurface.internalState.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(EmbeddedSurface.reactDashboard.label).last);
    await _pumpUntilFound(tester, find.textContaining('"reattached":true'));
    expect(find.textContaining('ERR '), findsNothing);
  }, skip: skip);
}

Future<ReactBridgeEvent> _waitFor(List<ReactBridgeEvent> events, bool Function(ReactBridgeEvent) test) async {
  while (true) {
    for (final ReactBridgeEvent e in events) {
      if (test(e)) return e;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<T> _pumpUntil<T>(WidgetTester tester, Future<T> future, {Duration timeout = const Duration(seconds: 30)}) async {
  bool done = false;
  late T value;
  Object? error;
  future.then((T v) {
    value = v;
    done = true;
  }, onError: (Object e) {
    error = e;
    done = true;
  });
  final DateTime deadline = DateTime.now().add(timeout);
  while (!done) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('_pumpUntil timed out', timeout);
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (error != null) throw error!;
  return value;
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      // Dump the visible log so a failure shows what JS actually sent.
      final Iterable<String> lines = find
          .byType(RichText)
          .evaluate()
          .map((Element e) => (e.widget as RichText).text.toPlainText())
          .where((String t) => RegExp(r'^\d\d:\d\d:\d\d').hasMatch(t));
      throw TimeoutException('Not found: $finder\nLog:\n${lines.join('\n')}', timeout);
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}
