import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_react_embed_platform_interface/flutter_react_embed_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

const ReactEngineConfig _config = ReactEngineConfig(
  engine: ReactEngineKind.reactNative,
  bundle: 'assets/checkout.hbc',
  requestTimeout: Duration(seconds: 2),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannelFlutterReactEmbed platform;
  late List<MethodCall> controlCalls;
  late List<Map<Object?, Object?>> delivered;
  late Object? Function(MethodCall call) controlReply;
  late List<FlutterErrorDetails> reportedErrors;
  late FlutterExceptionHandler? previousOnError;

  TestDefaultBinaryMessenger messenger() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Simulates native code calling into Dart on the message channel.
  Future<void> fromNative(String method, Map<String, Object?> args) async {
    await messenger().handlePlatformMessage(
      MethodChannelFlutterReactEmbed.messageChannelName,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (ByteData? _) {},
    );
  }

  Map<String, Object?> lastDeliveredFrame() => jsonDecode(delivered.last['frame']! as String) as Map<String, Object?>;

  setUp(() {
    platform = MethodChannelFlutterReactEmbed();
    controlCalls = <MethodCall>[];
    delivered = <Map<Object?, Object?>>[];
    reportedErrors = <FlutterErrorDetails>[];
    previousOnError = FlutterError.onError;
    FlutterError.onError = reportedErrors.add;
    controlReply = (MethodCall call) => switch (call.method) {
          'initializeEngine' => <String, Object?>{'runtimeId': 'rt-1'},
          _ => null,
        };

    messenger()
      ..setMockMethodCallHandler(platform.controlChannel, (MethodCall call) async {
        controlCalls.add(call);
        return controlReply(call);
      })
      ..setMockMethodCallHandler(platform.messageChannel, (MethodCall call) async {
        delivered.add(call.arguments as Map<Object?, Object?>);
        return null;
      });
  });

  tearDown(() {
    FlutterError.onError = previousOnError;
    messenger()
      ..setMockMethodCallHandler(platform.controlChannel, null)
      ..setMockMethodCallHandler(platform.messageChannel, null);
  });

  test('initializeEngine sends the config and returns a handle', () async {
    final ReactRuntimeHandle handle = await platform.initializeEngine(_config);
    expect(handle, const ReactRuntimeHandle(id: 'rt-1', engine: ReactEngineKind.reactNative));
    expect(controlCalls.single.method, 'initializeEngine');
    expect((controlCalls.single.arguments as Map<Object?, Object?>)['bundle'], 'assets/checkout.hbc');
  });

  test('maps native failures to typed exceptions', () async {
    controlReply = (MethodCall _) => throw PlatformException(code: 'BUNDLE_NOT_FOUND', message: 'missing');
    await expectLater(
      platform.initializeEngine(_config),
      throwsA(isA<ReactEngineInitializationException>()
          .having((ReactEngineInitializationException e) => e.code, 'code', 'BUNDLE_NOT_FOUND')),
    );

    controlReply = (MethodCall _) => <String, Object?>{'unexpected': true};
    await expectLater(platform.initializeEngine(_config), throwsA(isA<ReactEngineInitializationException>()));

    messenger().setMockMethodCallHandler(platform.controlChannel, null);
    await expectLater(platform.initializeEngine(_config), throwsA(isA<ReactEngineUnavailableException>()));
  });

  test('rejects an invalid config before reaching native code', () async {
    await expectLater(
      platform.initializeEngine(const ReactEngineConfig(engine: ReactEngineKind.web, bundle: ' ')),
      throwsA(isA<ReactConfigurationException>()),
    );
    expect(controlCalls, isEmpty);
  });

  test('invoke round-trips a JSON-RPC request through the native relay', () async {
    final ReactRuntimeHandle rt = await platform.initializeEngine(_config);
    final Future<Object?> result = platform.invoke(rt, 'getCart', params: <String, Object?>{'id': 9});
    await pumpEventQueue();

    final Map<String, Object?> request = lastDeliveredFrame();
    expect(delivered.last['runtimeId'], 'rt-1');
    expect(request['method'], 'getCart');

    await fromNative('onFrame', <String, Object?>{
      'runtimeId': 'rt-1',
      'frame': jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': <String, Object?>{'items': 2}
      }),
    });
    expect(await result, <String, Object?>{'items': 2});
  });

  test('buffers frames that arrive before initializeEngine returns', () async {
    // Native evaluates the bundle while initializeEngine is still in flight,
    // so JS's first notification reaches Dart before the runtime id does.
    controlReply = (MethodCall call) async {
      await fromNative('onFrame', <String, Object?>{
        'runtimeId': 'rt-1',
        'frame': jsonEncode(<String, Object?>{'jsonrpc': '2.0', 'method': 'hello'}),
      });
      return <String, Object?>{'runtimeId': 'rt-1'};
    };
    final ReactRuntimeHandle rt = await platform.initializeEngine(_config);
    await pumpEventQueue();
    // Delivered to the first listener even though it subscribed late.
    final ReactBridgeEvent event = await platform.events(rt).first.timeout(const Duration(seconds: 1));
    expect(event.name, 'hello');
  });

  test('emit wraps scalar data and events filter by name', () async {
    final ReactRuntimeHandle rt = await platform.initializeEngine(_config);
    await platform.emit(rt, 'localeChanged', data: 'de-DE');
    expect(lastDeliveredFrame()['params'], <String, Object?>{'value': 'de-DE'});

    final Future<ReactBridgeEvent> filtered = platform.events(rt, name: 'b').first;
    for (final String name in <String>['a', r'$/cancelRequest', 'b']) {
      await fromNative('onFrame', <String, Object?>{
        'runtimeId': 'rt-1',
        'frame': jsonEncode(<String, Object?>{'jsonrpc': '2.0', 'method': name}),
      });
    }
    expect((await filtered).name, 'b');
  });

  test('a fatal JS error fails pending requests and marks the runtime crashed', () async {
    final ReactRuntimeHandle rt = await platform.initializeEngine(_config);
    final Future<List<ReactRuntimeState>> states = platform.runtimeStates(rt).take(1).toList();
    final Future<void> pending = expectLater(platform.invoke(rt, 'slow'), throwsA(isA<ReactJsRuntimeException>()));
    await pumpEventQueue();

    await fromNative('onRuntimeError', <String, Object?>{
      'runtimeId': 'rt-1',
      'message': 'Invariant Violation',
      'stack': 'at render',
      'fatal': true,
    });
    await pending;
    expect(await states, <ReactRuntimeState>[ReactRuntimeState.crashed]);
  });

  test('updateProps validates JSON and sends it pre-encoded', () async {
    await platform.updateProps(4, <String, Object?>{'total': 12900});
    expect(controlCalls.single.arguments, <String, Object?>{'viewId': 4, 'propsJson': '{"total":12900}'});

    await expectLater(
      platform.updateProps(4, <String, Object?>{'bad': Object()}),
      throwsA(isA<ReactSerializationException>()),
    );
  });

  test('disposeEngine is idempotent and fails pending work', () async {
    final ReactRuntimeHandle rt = await platform.initializeEngine(_config);
    final Future<void> pending =
        expectLater(platform.invoke(rt, 'slow'), throwsA(isA<ReactRuntimeDisposedException>()));
    await pumpEventQueue();

    await platform.disposeEngine(rt);
    await platform.disposeEngine(rt);
    await pending;
    expect(controlCalls.where((MethodCall c) => c.method == 'disposeEngine'), hasLength(1));
    expect(platform.liveSessionCount, 0);
    expect(() => platform.invoke(rt, 'after'), throwsA(isA<ReactRuntimeDisposedException>()));
  });
}
