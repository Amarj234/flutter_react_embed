import 'dart:convert';

import 'package:flutter_react_embed_platform_interface/flutter_react_embed_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JsonSafety', () {
    test('accepts plain JSON', () {
      expect(
        () => JsonSafety.validate(<String, Object?>{
          'a': 1,
          'b': <Object?>[true, null, 'x', 1.5],
          'c': <String, Object?>{'d': <Object?>[]},
        }),
        returnsNormally,
      );
    });

    test('reports the path of a non-JSON value', () {
      expect(
        () => JsonSafety.validate(<String, Object?>{
          'items': <Object?>[
            1,
            <String, Object?>{'at': DateTime(2026)},
          ],
        }),
        throwsA(
          isA<ReactSerializationException>().having(
            (ReactSerializationException e) => e.path,
            'path',
            r'$.items[1].at',
          ),
        ),
      );
    });

    test('rejects NaN, unsafe integers and non-string keys', () {
      expect(() => JsonSafety.validate(double.nan), throwsA(isA<ReactSerializationException>()));
      expect(() => JsonSafety.validate(JsonSafety.maxSafeInteger + 1), throwsA(isA<ReactSerializationException>()));
      expect(() => JsonSafety.validate(<Object?, Object?>{1: 'x'}), throwsA(isA<ReactSerializationException>()));
    });

    test('rejects cyclic structures via the depth limit', () {
      final List<Object?> cyclic = <Object?>[];
      cyclic.add(cyclic);
      expect(() => JsonSafety.validate(cyclic), throwsA(isA<ReactSerializationException>()));
    });
  });

  group('JsonRpcCodec.decode', () {
    const JsonRpcCodec codec = JsonRpcCodec();

    test('classifies requests, notifications and responses', () {
      final JsonRpcDecodeResultMatcher result = JsonRpcDecodeResultMatcher(
        codec.decode(
          jsonEncode(<Object?>[
            <String, Object?>{'jsonrpc': '2.0', 'id': 1, 'method': 'm', 'params': <Object?>[]},
            <String, Object?>{'jsonrpc': '2.0', 'method': 'evt'},
            <String, Object?>{'jsonrpc': '2.0', 'id': 'a', 'result': null},
            <String, Object?>{
              'jsonrpc': '2.0',
              'id': 2,
              'error': <String, Object?>{'code': -32000, 'message': 'boom'},
            },
          ]),
        ),
      );
      expect(result.types, <Type>[JsonRpcRequest, JsonRpcNotification, JsonRpcSuccess, JsonRpcFailure]);
      expect(result.rejectCodes, isEmpty);
    });

    test('answers malformed JSON with a parse error', () {
      expect(JsonRpcDecodeResultMatcher(codec.decode('{nope')).rejectCodes, <int>[JsonRpcErrorCode.parseError]);
    });

    test('rejects invalid entries but keeps valid ones in a batch', () {
      final JsonRpcDecodeResultMatcher result = JsonRpcDecodeResultMatcher(
        codec.decode(
          jsonEncode(<Object?>[
            <String, Object?>{'jsonrpc': '1.0', 'id': 7, 'method': 'old'},
            <String, Object?>{'jsonrpc': '2.0', 'method': 'ok'},
            <String, Object?>{'jsonrpc': '2.0', 'id': 3, 'method': 'bad', 'params': 5},
          ]),
        ),
      );
      expect(result.types, <Type>[JsonRpcNotification]);
      expect(result.rejectCodes, <int>[JsonRpcErrorCode.invalidRequest, JsonRpcErrorCode.invalidRequest]);
      expect(result.rejectIds, <Object?>[7, 3]);
    });

    test('rejects oversized frames', () {
      final JsonRpcDecodeResultMatcher result = JsonRpcDecodeResultMatcher(
        const JsonRpcCodec(maxMessageBytes: 16).decode('"${'x' * 64}"'),
      );
      expect(result.rejectCodes, <int>[JsonRpcErrorCode.payloadTooLarge]);
    });
  });

  group('JsonRpcEndpoint', () {
    late List<Map<String, Object?>> sent;
    late JsonRpcEndpoint endpoint;
    late List<ReactProtocolException> protocolErrors;

    setUp(() {
      sent = <Map<String, Object?>>[];
      protocolErrors = <ReactProtocolException>[];
      endpoint = JsonRpcEndpoint(
        runtimeId: 'rt',
        defaultTimeout: const Duration(seconds: 1),
        send: (String frame) async => sent.add(jsonDecode(frame) as Map<String, Object?>),
        onProtocolError: protocolErrors.add,
      );
    });

    tearDown(() => endpoint.close());

    test('correlates a response with its request', () async {
      final Future<Object?> reply = endpoint.request('add', params: <Object?>[1, 2]);
      await pumpEventQueue();
      final Object? id = sent.single['id'];
      await endpoint.handleFrame(jsonEncode(<String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': 3}));
      expect(await reply, 3);
      expect(endpoint.pendingRequestCount, 0);
    });

    test('maps a JS exception to ReactJsRuntimeException with its stack', () async {
      final Future<void> expectation = expectLater(
        endpoint.request('explode'),
        throwsA(
          isA<ReactJsRuntimeException>().having(
            (ReactJsRuntimeException e) => e.jsStack,
            'jsStack',
            'at App (App.tsx:4)',
          ),
        ),
      );
      await pumpEventQueue();
      await endpoint.handleFrame(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': sent.single['id'],
          'error': <String, Object?>{
            'code': JsonRpcErrorCode.jsRuntimeException,
            'message': 'TypeError: x is undefined',
            'data': <String, Object?>{'stack': 'at App (App.tsx:4)'},
          },
        }),
      );
      await expectation;
    });

    test('times out, sends a cancel notification and drops the late response', () async {
      await expectLater(
        endpoint.request('slow', timeout: const Duration(milliseconds: 20)),
        throwsA(isA<ReactRpcTimeoutException>()),
      );
      await pumpEventQueue();
      expect(sent.last['method'], JsonRpcEndpoint.cancelRequestMethod);

      await endpoint.handleFrame(jsonEncode(<String, Object?>{'jsonrpc': '2.0', 'id': 1, 'result': 'late'}));
      expect(protocolErrors, hasLength(1));
    });

    test('rejects non-JSON params before sending anything', () async {
      await expectLater(
        endpoint.request('m', params: <String, Object?>{'when': DateTime(2026)}),
        throwsA(isA<ReactSerializationException>()),
      );
      expect(sent, isEmpty);
      expect(endpoint.pendingRequestCount, 0);
    });

    test('dispatches JS requests to Dart handlers', () async {
      endpoint.registerMethod('double', (Object? params) => ((params! as List<Object?>).single! as int) * 2);
      await endpoint.handleFrame(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 'js-1',
          'method': 'double',
          'params': <Object?>[21],
        }),
      );
      expect(sent.single, <String, Object?>{'jsonrpc': '2.0', 'id': 'js-1', 'result': 42});
    });

    test('answers unknown methods, typed and untyped handler failures', () async {
      endpoint
        ..registerMethod(
          'invalid',
          (Object? _) => throw const ReactRpcException('bad', code: JsonRpcErrorCode.invalidParams),
        )
        ..registerMethod('crash', (Object? _) => throw StateError('boom'))
        ..registerMethod('nonJson', (Object? _) => DateTime(2026));
      for (final String method in <String>['missing', 'invalid', 'crash', 'nonJson']) {
        await endpoint.handleFrame(jsonEncode(<String, Object?>{'jsonrpc': '2.0', 'id': method, 'method': method}));
      }
      final List<Object?> codes = sent
          .map((Map<String, Object?> m) => (m['error']! as Map<String, Object?>)['code'])
          .toList();
      expect(codes, <int>[
        JsonRpcErrorCode.methodNotFound,
        JsonRpcErrorCode.invalidParams,
        JsonRpcErrorCode.internalError,
        JsonRpcErrorCode.internalError,
      ]);
    });

    test('streams notifications and fails pending requests on close', () async {
      final Future<JsonRpcNotification> event = endpoint.notifications.first;
      await endpoint.handleFrame(jsonEncode(<String, Object?>{'jsonrpc': '2.0', 'method': 'cartChanged'}));
      expect((await event).method, 'cartChanged');

      final Future<void> pending = expectLater(
        endpoint.request('never'),
        throwsA(isA<ReactRuntimeDisposedException>()),
      );
      await pumpEventQueue();
      await endpoint.close();
      await pending;
      await expectLater(endpoint.request('after'), throwsA(isA<ReactRuntimeDisposedException>()));
    });
  });
}

/// Small helper to keep assertions on decode results readable.
class JsonRpcDecodeResultMatcher {
  JsonRpcDecodeResultMatcher(this.result);

  final JsonRpcDecodeResult result;

  List<Type> get types => <Type>[for (final JsonRpcMessage m in result.messages) m.runtimeType];

  List<int> get rejectCodes => <int>[for (final JsonRpcFailure f in result.rejects) f.error.code];

  List<Object?> get rejectIds => <Object?>[for (final JsonRpcFailure f in result.rejects) f.id];
}
