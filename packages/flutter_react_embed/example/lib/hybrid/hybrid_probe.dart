import 'dart:async';

import 'package:flutter_react_embed/flutter_react_embed.dart';

/// Whether the app was built with React Native linked
/// (`--dart-define=FRE_REACT_NATIVE=true`, set by tool/run_local_test.sh).
const bool kReactNativeLinked = bool.fromEnvironment('FRE_REACT_NATIVE');

/// Number of automatic web <-> native switches per round the harness runs on
/// start (`--dart-define=FRE_AUTOCYCLE=20`). Zero means interactive only.
const int kAutoCycles = int.fromEnvironment('FRE_AUTOCYCLE');

/// Rounds of [kAutoCycles] switches (`--dart-define=FRE_ROUNDS=4`). After each
/// round the harness unmounts the view and idles for [kRoundIdle], logging
/// `ROUND <n>/<total> DONE`, so the script can sample memory between rounds.
const int kRounds = int.fromEnvironment('FRE_ROUNDS', defaultValue: 1);

/// Idle time after each round; the script's GC + meminfo sample runs in it.
const Duration kRoundIdle = Duration(seconds: 8);

/// Prefix of every harness log line, grepped from logcat by the script.
const String kLogTag = 'FRE_HARNESS';

/// The configuration each [ReactEmbedType] is probed with.
///
/// Both fixtures implement the same contract: `add`, `echo`, `throwError`,
/// `ping` -> `pong`, and `mounted` / `propsApplied` events.
ReactViewConfiguration hybridConfiguration(ReactEmbedType type, {required int generation}) {
  final JsonMap props = <String, Object?>{'label': '${type.name} #$generation', 'generation': generation};
  return switch (type) {
    ReactEmbedType.web => ReactViewConfiguration.web(
      assetPath: 'assets/demo_spa/',
      route: '/probe',
      initialProps: props,
      requestTimeout: const Duration(seconds: 5),
    ),
    ReactEmbedType.native => ReactViewConfiguration.native(
      bundleName: 'assets/rn/index.android.bundle',
      iosBundleName: 'assets/rn/main.jsbundle',
      componentName: 'FreProbe',
      initialProps: props,
      requestTimeout: const Duration(seconds: 5),
    ),
  };
}

/// Records every bridge event of one surface from the moment it is created,
/// so checks can wait for events that may already have arrived.
final class ProbeEventLog {
  /// Starts recording [controller]'s events.
  ProbeEventLog(ReactViewController controller) {
    _subscription = controller.events().listen((ReactBridgeEvent event) {
      _events.add(event);
      for (final _Waiter waiter in List<_Waiter>.of(_waiters)) {
        if (waiter.matches(event)) {
          _waiters.remove(waiter);
          waiter.completer.complete(event);
        }
      }
    });
  }

  final List<ReactBridgeEvent> _events = <ReactBridgeEvent>[];
  final List<_Waiter> _waiters = <_Waiter>[];
  late final StreamSubscription<ReactBridgeEvent> _subscription;

  /// Names of every event received so far, in order.
  List<String> get names => _events.map((ReactBridgeEvent e) => e.name).toList();

  /// Completes with the first event named [name] (and matching [where]),
  /// including one received before the call.
  Future<ReactBridgeEvent> waitFor(
    String name, {
    bool Function(Object? data)? where,
    Duration timeout = const Duration(seconds: 15),
  }) {
    final _Waiter waiter = _Waiter(name, where);
    for (final ReactBridgeEvent event in _events) {
      if (waiter.matches(event)) {
        return Future<ReactBridgeEvent>.value(event);
      }
    }
    _waiters.add(waiter);
    return waiter.completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(waiter);
        throw TimeoutException('No "$name" event within $timeout (received: ${names.join(', ')})');
      },
    );
  }

  /// Stops recording.
  Future<void> close() => _subscription.cancel();
}

final class _Waiter {
  _Waiter(this.name, this.where);

  final String name;
  final bool Function(Object? data)? where;
  final Completer<ReactBridgeEvent> completer = Completer<ReactBridgeEvent>();

  bool matches(ReactBridgeEvent event) => event.name == name && (where?.call(event.data) ?? true);
}

/// Result of [exerciseSurface].
final class ProbeResult {
  const ProbeResult(this.type, this.elapsed);

  /// Engine type that was exercised.
  final ReactEmbedType type;

  /// Time from view creation to the last check passing.
  final Duration elapsed;
}

/// Runs the contract checks against a freshly created surface. Throws a
/// [StateError] (or the bridge's own exception) on the first failure.
///
/// 1. JS mounted the surface (`mounted` event).
/// 2. Dart -> JS request with a result (`add`) and with nested JSON (`echo`).
/// 3. JS errors map to [ReactJsRuntimeException] (`throwError`).
/// 4. Dart -> JS event and its JS -> Dart reply (`ping` -> `pong`).
/// 5. A props update reaches JS without a remount (`propsApplied`).
Future<ProbeResult> exerciseSurface(
  ReactEmbedType type,
  ReactViewController controller,
  ProbeEventLog log, {
  required int generation,
}) async {
  final Stopwatch watch = Stopwatch()..start();

  await log.waitFor('mounted');

  final Object? sum = await controller.invoke<Object?>('add', params: <String, Object?>{'a': 2, 'b': 3});
  _check(sum == 5, 'add(2, 3) returned $sum');

  final JsonMap nested = <String, Object?>{
    'list': <Object?>[1, 'two', null, true],
    'map': <String, Object?>{'k': 1.5},
  };
  final Object? echoed = await controller.invoke<Object?>('echo', params: nested);
  _check(echoed.toString() == nested.toString(), 'echo returned $echoed');

  try {
    await controller.invoke<Object?>('throwError');
    throw StateError('throwError did not throw');
  } on ReactJsRuntimeException {
    // Expected.
  }

  final Future<ReactBridgeEvent> pong = log.waitFor(
    'pong',
    where: (Object? data) => data is Map && data['n'] == generation,
  );
  await controller.emit('ping', <String, Object?>{'n': generation});
  await pong;

  final int bumped = generation + 100000;
  final Future<ReactBridgeEvent> applied = log.waitFor(
    'propsApplied',
    where: (Object? data) => data is Map && data['generation'] == bumped,
  );
  await controller.updateProps(<String, Object?>{'label': '${type.name} #$bumped', 'generation': bumped});
  await applied;

  return ProbeResult(type, watch.elapsed);
}

void _check(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
