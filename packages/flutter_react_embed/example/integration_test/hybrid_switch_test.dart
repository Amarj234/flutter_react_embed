import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_react_embed/flutter_react_embed.dart';
import 'package:flutter_react_embed_example/hybrid/hybrid_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// On-device checks for switching one ReactView between ReactEmbedType.web
/// and ReactEmbedType.native. Run through tool/run_local_test.sh, which builds
/// the React Native probe bundle and passes --dart-define=FRE_REACT_NATIVE=true.
/// Without it, only the web half runs.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Mounts [type] in a fresh ReactView, runs the contract checks, and
  /// returns the controller (still mounted) plus any errors the view raised.
  Future<(ReactViewController, List<ReactEmbedException>)> mountAndProbe(
    WidgetTester tester,
    ReactEmbedType type,
    int generation,
  ) async {
    final Completer<(ReactViewController, ProbeEventLog)> created = Completer<(ReactViewController, ProbeEventLog)>();
    final List<ReactEmbedException> errors = <ReactEmbedException>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReactView(
            key: ValueKey<int>(generation),
            configuration: hybridConfiguration(type, generation: generation),
            onViewCreated: (ReactViewController c) {
              if (!created.isCompleted) created.complete((c, ProbeEventLog(c)));
            },
            onError: (ReactEmbedException e, StackTrace _) {
              errors.add(e);
              if (!created.isCompleted) created.completeError(e);
            },
          ),
        ),
      ),
    );
    final (ReactViewController controller, ProbeEventLog log) = await _pumpUntil(tester, created.future);
    try {
      await _pumpUntil(tester, exerciseSurface(type, controller, log, generation: generation));
    } finally {
      await log.close();
    }
    return (controller, errors);
  }

  testWidgets('web engine passes the contract checks', (WidgetTester tester) async {
    final (ReactViewController controller, List<ReactEmbedException> errors) = await mountAndProbe(
      tester,
      ReactEmbedType.web,
      1,
    );
    expect(controller.runtime.engine, ReactEngineKind.web);
    expect(errors, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(controller.isDisposed, isTrue);
  });

  testWidgets('native engine passes the contract checks', (WidgetTester tester) async {
    final (ReactViewController controller, List<ReactEmbedException> errors) = await mountAndProbe(
      tester,
      ReactEmbedType.native,
      2,
    );
    expect(controller.runtime.engine, ReactEngineKind.reactNative);
    expect(errors, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(controller.isDisposed, isTrue);
  }, skip: !kReactNativeLinked);

  testWidgets('switches web <-> native repeatedly and releases every runtime', (WidgetTester tester) async {
    final FlutterReactEmbedPlatform platform = FlutterReactEmbedPlatform.instance;
    final List<ReactRuntimeHandle> runtimes = <ReactRuntimeHandle>[];
    for (int i = 0; i < 10; i++) {
      final ReactEmbedType type = i.isEven ? ReactEmbedType.web : ReactEmbedType.native;
      final (ReactViewController controller, List<ReactEmbedException> errors) = await mountAndProbe(
        tester,
        type,
        100 + i,
      );
      expect(errors, isEmpty, reason: 'cycle $i (${type.name})');
      runtimes.add(controller.runtime);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    // Give the native disposals (posted to the platform thread) time to land.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));

    // Every owned runtime was disposed with its view: Dart rejects calls on it.
    for (final ReactRuntimeHandle runtime in runtimes) {
      expect(
        () => platform.invoke(runtime, 'add', params: <String, Object?>{'a': 1, 'b': 1}),
        throwsA(isA<ReactRuntimeDisposedException>()),
        reason: runtime.toString(),
      );
    }
    expect(runtimes.map((ReactRuntimeHandle r) => r.id).toSet(), hasLength(runtimes.length));
  }, skip: !kReactNativeLinked);
}

/// Pumps frames until [future] completes, so platform views and channel
/// replies make progress while the test waits.
Future<T> _pumpUntil<T>(WidgetTester tester, Future<T> future, {Duration timeout = const Duration(seconds: 30)}) async {
  bool done = false;
  late T value;
  Object? error;
  StackTrace? stackTrace;
  future.then(
    (T v) {
      value = v;
      done = true;
    },
    onError: (Object e, StackTrace s) {
      error = e;
      stackTrace = s;
      done = true;
    },
  );
  final DateTime deadline = DateTime.now().add(timeout);
  while (!done) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('_pumpUntil timed out', timeout);
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (error != null) {
    Error.throwWithStackTrace(error!, stackTrace ?? StackTrace.current);
  }
  return value;
}
