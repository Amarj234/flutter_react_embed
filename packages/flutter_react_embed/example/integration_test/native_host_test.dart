import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_react_embed/flutter_react_embed.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const ReactEngineConfig _web = ReactEngineConfig(
  engine: ReactEngineKind.web,
  bundle: 'assets/demo_spa/',
  requestTimeout: Duration(seconds: 5),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final FlutterReactEmbedPlatform platform = FlutterReactEmbedPlatform.instance;

  testWidgets('boots the web engine and round-trips JSON-RPC both ways', (WidgetTester tester) async {
    final ReactRuntimeHandle rt = await platform.initializeEngine(_web);
    try {
      // `hello` was JS's readiness frame, sent before initializeEngine replied.
      final ReactBridgeEvent hello = await platform.events(rt).first.timeout(const Duration(seconds: 5));
      expect(hello.name, 'hello');
      final Map<String, Object?> info = hello.data! as Map<String, Object?>;
      expect(info['runtimeId'], rt.id);
      expect(info['platform'], anyOf('android', 'ios'));

      expect(await platform.invoke(rt, 'add', params: <String, Object?>{'a': 2, 'b': 3}), 5);
      expect(
        await platform.invoke(
          rt,
          'echo',
          params: <String, Object?>{
            'nested': <Object?>[1, 'two', null],
          },
        ),
        <String, Object?>{
          'nested': <Object?>[1, 'two', null],
        },
      );
      await expectLater(
        platform.invoke(rt, 'throwError'),
        throwsA(isA<ReactJsRuntimeException>().having((ReactJsRuntimeException e) => e.jsStack, 'jsStack', isNotNull)),
      );
      await expectLater(
        platform.invoke(rt, 'missing'),
        throwsA(
          isA<ReactRpcException>().having((ReactRpcException e) => e.code, 'code', JsonRpcErrorCode.methodNotFound),
        ),
      );

      final Future<ReactBridgeEvent> pong = platform.events(rt, name: 'pong').first;
      await platform.emit(rt, 'ping', data: <String, Object?>{'n': 7});
      expect((await pong.timeout(const Duration(seconds: 5))).data, <String, Object?>{'n': 7});
    } finally {
      await platform.disposeEngine(rt);
    }
    expect(() => platform.invoke(rt, 'add'), throwsA(isA<ReactRuntimeDisposedException>()));
  });

  testWidgets('reports a missing bundle and the unsupported react_native engine', (WidgetTester tester) async {
    await expectLater(
      platform.initializeEngine(const ReactEngineConfig(engine: ReactEngineKind.web, bundle: 'assets/nope/')),
      throwsA(
        isA<ReactEngineInitializationException>().having(
          (ReactEngineInitializationException e) => e.code,
          'code',
          'BUNDLE_NOT_FOUND',
        ),
      ),
    );
    await expectLater(
      platform.initializeEngine(const ReactEngineConfig(engine: ReactEngineKind.reactNative, bundle: 'assets/x.hbc')),
      throwsA(
        isA<ReactEngineInitializationException>().having(
          (ReactEngineInitializationException e) => e.code,
          'code',
          'UNSUPPORTED_ENGINE',
        ),
      ),
    );
  });

  testWidgets('rejects a bundle whose sha256 does not match', (WidgetTester tester) async {
    await expectLater(
      platform.initializeEngine(
        ReactEngineConfig(engine: ReactEngineKind.web, bundle: 'assets/demo_spa/', bundleSha256: '0' * 64),
      ),
      throwsA(
        isA<ReactEngineInitializationException>().having(
          (ReactEngineInitializationException e) => e.code,
          'code',
          'BUNDLE_INTEGRITY',
        ),
      ),
    );
  });

  testWidgets('ReactView mounts the surface, pushes props and unmounts', (WidgetTester tester) async {
    final Completer<ReactViewController> created = Completer<ReactViewController>();
    final List<ReactEmbedException> errors = <ReactEmbedException>[];

    Widget app(int count) => MaterialApp(
      home: Scaffold(
        body: ReactView(
          configuration: ReactViewConfiguration(
            engine: _web,
            moduleName: '/checkout',
            initialProps: <String, Object?>{'count': count},
          ),
          onViewCreated: (ReactViewController c) {
            if (!created.isCompleted) created.complete(c);
          },
          onError: (ReactEmbedException e, StackTrace _) => errors.add(e),
        ),
      ),
    );

    await tester.pumpWidget(app(0));
    final ReactViewController controller = await _pumpUntil(tester, created.future);

    final Map<String, Object?> described = await _pumpUntil(
      tester,
      controller.invoke<Map<String, Object?>>('describe'),
    );
    final Map<String, Object?> mounted = described['mounted']! as Map<String, Object?>;
    expect(mounted['moduleName'], '/checkout');
    expect(mounted['props'], <String, Object?>{'count': 0});
    expect(mounted['viewId'], controller.viewId);

    final Future<ReactBridgeEvent> applied = controller.events(name: 'propsApplied').first;
    await tester.pumpWidget(app(1));
    expect((await _pumpUntil(tester, applied)).data, <String, Object?>{'count': 1});

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(controller.isDisposed, isTrue);
    expect(errors, isEmpty);
  });
}

/// Pumps frames until [future] completes; platform views need frames to be
/// created, so a bare `await` could stall.
Future<T> _pumpUntil<T>(WidgetTester tester, Future<T> future, {Duration timeout = const Duration(seconds: 15)}) async {
  bool done = false;
  late T value;
  Object? error;
  future.then(
    (T v) {
      value = v;
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  final DateTime deadline = DateTime.now().add(timeout);
  while (!done) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting in _pumpUntil', timeout);
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (error != null) throw error!;
  return value;
}
