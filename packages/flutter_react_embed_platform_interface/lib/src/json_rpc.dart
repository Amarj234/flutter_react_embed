/// JSON-RPC 2.0 implementation used on every Dart <-> JavaScript link.
///
/// The layer is transport-agnostic: [JsonRpcEndpoint] only needs a function
/// that ships a `String` frame and a call to [JsonRpcEndpoint.handleFrame] for
/// every inbound frame. The MethodChannel transport is one such binding; an
/// FFI/JSI transport can reuse the endpoint unchanged.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'errors.dart';
import 'types.dart';

/// Standard and bridge-specific JSON-RPC error codes.
abstract final class JsonRpcErrorCode {
  /// Invalid JSON was received.
  static const int parseError = -32700;

  /// The JSON is not a valid request object.
  static const int invalidRequest = -32600;

  /// The method does not exist or is not registered.
  static const int methodNotFound = -32601;

  /// Invalid method parameters.
  static const int invalidParams = -32602;

  /// Internal error inside the handler.
  static const int internalError = -32603;

  /// JavaScript threw while handling the request. `data.stack` holds the stack.
  static const int jsRuntimeException = -32000;

  /// The runtime is not ready or was disposed.
  static const int runtimeUnavailable = -32001;

  /// The handler did not finish before its deadline.
  static const int requestTimeout = -32002;

  /// The encoded frame exceeds the negotiated size limit.
  static const int payloadTooLarge = -32003;
}

/// Validates and encodes Dart values as bridge-safe JSON.
///
/// Stricter than `jsonEncode`: it rejects non-finite doubles, integers that
/// JavaScript cannot represent exactly, non-`String` map keys, and nesting
/// deeper than [maxDepth] (which also catches cyclic structures). Errors carry
/// the JSONPath of the offending value.
abstract final class JsonSafety {
  /// Maximum nesting depth accepted on the bridge.
  static const int maxDepth = 64;

  /// Largest integer JavaScript represents exactly (2^53 - 1).
  static const int maxSafeInteger = 9007199254740991;

  /// Throws [ReactSerializationException] if [value] is not bridge-safe JSON.
  static void validate(Object? value, {String path = r'$'}) => _validate(value, path, 0);

  /// Validates [value] and encodes it as a JSON string.
  static String encode(Object? value, {String path = r'$'}) {
    validate(value, path: path);
    return jsonEncode(value);
  }

  static void _validate(Object? value, String path, int depth) {
    if (depth > maxDepth) {
      throw ReactSerializationException(
        'Nesting deeper than $maxDepth levels (cyclic structure?)',
        path: path,
      );
    }
    switch (value) {
      case null || bool() || String():
        return;
      case int():
        if (value > maxSafeInteger || value < -maxSafeInteger) {
          throw ReactSerializationException(
            'Integer $value exceeds the JavaScript safe integer range; '
            'send it as a String',
            path: path,
          );
        }
      case double():
        if (!value.isFinite) {
          throw ReactSerializationException(
            'Non-finite double $value is not valid JSON',
            path: path,
          );
        }
      case List<Object?>():
        for (int i = 0; i < value.length; i++) {
          _validate(value[i], '$path[$i]', depth + 1);
        }
      case Map<Object?, Object?>():
        for (final MapEntry<Object?, Object?> entry in value.entries) {
          final Object? key = entry.key;
          if (key is! String) {
            throw ReactSerializationException(
              'Map key $key (${key.runtimeType}) is not a String',
              path: path,
            );
          }
          _validate(entry.value, '$path.$key', depth + 1);
        }
      default:
        throw ReactSerializationException(
          'Value of type ${value.runtimeType} is not JSON-encodable; '
          'convert it to a Map, List, String, num, bool or null first',
          path: path,
        );
    }
  }
}

/// Base type of every JSON-RPC 2.0 message.
@immutable
sealed class JsonRpcMessage {
  const JsonRpcMessage();

  /// JSON representation, including the `"jsonrpc": "2.0"` member.
  JsonMap toJson();
}

/// A call that expects a response.
final class JsonRpcRequest extends JsonRpcMessage {
  /// Creates a request. [id] must be an `int` or a `String`.
  const JsonRpcRequest({required this.id, required this.method, this.params});

  /// Correlation id.
  final Object id;

  /// Method name.
  final String method;

  /// A [JsonMap], a `List<Object?>` or `null`.
  final Object? params;

  @override
  JsonMap toJson() => <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        if (params != null) 'params': params,
      };
}

/// A call without a response (an event).
final class JsonRpcNotification extends JsonRpcMessage {
  /// Creates a notification.
  const JsonRpcNotification({required this.method, this.params});

  /// Method (event) name.
  final String method;

  /// A [JsonMap], a `List<Object?>` or `null`.
  final Object? params;

  @override
  JsonMap toJson() => <String, Object?>{
        'jsonrpc': '2.0',
        'method': method,
        if (params != null) 'params': params,
      };
}

/// A successful response.
final class JsonRpcSuccess extends JsonRpcMessage {
  /// Creates a success response.
  const JsonRpcSuccess({required this.id, required this.result});

  /// Id of the request being answered.
  final Object id;

  /// Result value (any JSON value, including `null`).
  final Object? result;

  @override
  JsonMap toJson() => <String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': result};
}

/// An error response.
final class JsonRpcFailure extends JsonRpcMessage {
  /// Creates an error response. [id] is `null` only when the request id could
  /// not be determined (parse errors, invalid requests).
  const JsonRpcFailure({required this.id, required this.error});

  /// Id of the request being answered, or `null`.
  final Object? id;

  /// The error object.
  final JsonRpcError error;

  @override
  JsonMap toJson() => <String, Object?>{'jsonrpc': '2.0', 'id': id, 'error': error.toJson()};
}

/// The `error` member of a [JsonRpcFailure].
@immutable
final class JsonRpcError {
  /// Creates an error object.
  const JsonRpcError({required this.code, required this.message, this.data});

  /// Error code (see [JsonRpcErrorCode]).
  final int code;

  /// Short description.
  final String message;

  /// Optional structured details.
  final Object? data;

  /// JSON representation.
  JsonMap toJson() => <String, Object?>{
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      };

  /// Converts the error into the matching [ReactEmbedException] subtype.
  ReactEmbedException toException() {
    if (code == JsonRpcErrorCode.jsRuntimeException) {
      final Object? details = data;
      final Object? stack = details is Map<String, Object?> ? details['stack'] : null;
      return ReactJsRuntimeException(
        message,
        jsStack: stack is String ? stack : null,
      );
    }
    return ReactRpcException(message, code: code, data: data);
  }
}

/// Result of decoding one inbound frame.
@immutable
final class JsonRpcDecodeResult {
  /// Creates a decode result.
  const JsonRpcDecodeResult({required this.messages, required this.rejects});

  /// Well-formed messages, in frame order.
  final List<JsonRpcMessage> messages;

  /// Error responses that must be sent back for malformed entries.
  final List<JsonRpcFailure> rejects;
}

/// Encodes and strictly decodes JSON-RPC 2.0 frames, including batches.
@immutable
final class JsonRpcCodec {
  /// Creates a codec that refuses frames larger than [maxMessageBytes].
  const JsonRpcCodec({this.maxMessageBytes = 1024 * 1024});

  /// Upper bound for one frame, in UTF-8 bytes.
  final int maxMessageBytes;

  /// Encodes [message], validating every value it carries.
  ///
  /// Throws [ReactSerializationException] when a value is not bridge-safe JSON
  /// or the frame exceeds [maxMessageBytes].
  String encode(JsonRpcMessage message) {
    final JsonMap json = message.toJson();
    final String frame = JsonSafety.encode(json);
    _checkSize(frame);
    return frame;
  }

  /// Decodes an inbound frame.
  ///
  /// Never throws for malformed content: invalid entries become [rejects]
  /// that the caller sends back, as the JSON-RPC specification requires.
  JsonRpcDecodeResult decode(String frame) {
    if (utf8.encode(frame).length > maxMessageBytes) {
      return JsonRpcDecodeResult(
        messages: const <JsonRpcMessage>[],
        rejects: <JsonRpcFailure>[
          _reject(null, JsonRpcErrorCode.payloadTooLarge, 'Frame exceeds $maxMessageBytes bytes'),
        ],
      );
    }
    final Object? json;
    try {
      json = jsonDecode(frame);
    } on FormatException catch (e) {
      return JsonRpcDecodeResult(
        messages: const <JsonRpcMessage>[],
        rejects: <JsonRpcFailure>[_reject(null, JsonRpcErrorCode.parseError, e.message)],
      );
    }

    final List<JsonRpcMessage> messages = <JsonRpcMessage>[];
    final List<JsonRpcFailure> rejects = <JsonRpcFailure>[];
    final List<Object?> entries = switch (json) {
      final List<Object?> batch => batch,
      _ => <Object?>[json],
    };
    if (entries.isEmpty) {
      rejects.add(_reject(null, JsonRpcErrorCode.invalidRequest, 'Empty batch'));
    }
    for (final Object? entry in entries) {
      try {
        messages.add(_decodeOne(entry));
      } on _InvalidMessage catch (e) {
        rejects.add(_reject(e.id, JsonRpcErrorCode.invalidRequest, e.reason));
      }
    }
    return JsonRpcDecodeResult(messages: messages, rejects: rejects);
  }

  void _checkSize(String frame) {
    final int bytes = utf8.encode(frame).length;
    if (bytes > maxMessageBytes) {
      throw ReactSerializationException(
        'Encoded frame is $bytes bytes; limit is $maxMessageBytes',
        path: r'$',
      );
    }
  }

  static JsonRpcFailure _reject(Object? id, int code, String message) =>
      JsonRpcFailure(id: id, error: JsonRpcError(code: code, message: message));

  static JsonRpcMessage _decodeOne(Object? entry) {
    if (entry is! Map<String, Object?>) {
      throw const _InvalidMessage(null, 'Message is not a JSON object');
    }
    final Object? rawId = entry['id'];
    final Object? id = (rawId is int || rawId is String) ? rawId : null;
    if (entry['jsonrpc'] != '2.0') {
      throw _InvalidMessage(id, 'Missing or unsupported "jsonrpc" version');
    }
    if (entry.containsKey('id') && rawId != null && id == null) {
      throw const _InvalidMessage(null, '"id" must be an integer or a string');
    }

    if (entry.containsKey('method')) {
      final Object? method = entry['method'];
      if (method is! String || method.isEmpty) {
        throw _InvalidMessage(id, '"method" must be a non-empty string');
      }
      final Object? params = entry['params'];
      if (params != null && params is! Map<String, Object?> && params is! List<Object?>) {
        throw _InvalidMessage(id, '"params" must be an object or an array');
      }
      if (!entry.containsKey('id')) {
        return JsonRpcNotification(method: method, params: params);
      }
      if (id == null) {
        throw const _InvalidMessage(null, 'Request "id" must not be null');
      }
      return JsonRpcRequest(id: id, method: method, params: params);
    }

    final bool hasResult = entry.containsKey('result');
    final bool hasError = entry.containsKey('error');
    if (hasResult == hasError) {
      throw _InvalidMessage(id, 'Response must contain exactly one of "result" or "error"');
    }
    if (hasResult) {
      if (id == null) {
        throw const _InvalidMessage(null, 'Success response requires an "id"');
      }
      return JsonRpcSuccess(id: id, result: entry['result']);
    }
    final Object? error = entry['error'];
    if (error is! Map<String, Object?>) {
      throw _InvalidMessage(id, '"error" must be an object');
    }
    final Object? code = error['code'];
    final Object? message = error['message'];
    if (code is! int || message is! String) {
      throw _InvalidMessage(id, '"error" requires an integer "code" and a string "message"');
    }
    return JsonRpcFailure(
      id: id,
      error: JsonRpcError(code: code, message: message, data: error['data']),
    );
  }
}

final class _InvalidMessage implements Exception {
  const _InvalidMessage(this.id, this.reason);
  final Object? id;
  final String reason;
}

/// Ships one encoded frame to the remote peer.
typedef JsonRpcFrameSink = Future<void> Function(String frame);

/// One side of a bidirectional JSON-RPC session.
///
/// Correlates outbound requests with responses, enforces deadlines, dispatches
/// inbound requests to registered handlers and exposes inbound notifications
/// as a broadcast stream. All pending requests fail with
/// [ReactRuntimeDisposedException] when the endpoint closes.
final class JsonRpcEndpoint {
  /// Creates an endpoint that writes frames through [send].
  JsonRpcEndpoint({
    required JsonRpcFrameSink send,
    required this.runtimeId,
    this.codec = const JsonRpcCodec(),
    this.defaultTimeout = const Duration(seconds: 10),
    this.onProtocolError,
  }) : _send = send;

  /// Runtime this endpoint talks to; used in error messages.
  final String runtimeId;

  /// Frame codec.
  final JsonRpcCodec codec;

  /// Deadline applied when [request] is called without a timeout.
  final Duration defaultTimeout;

  /// Receives frames that could not be processed (malformed or orphaned).
  final void Function(ReactProtocolException error)? onProtocolError;

  /// Notification sent when a request times out, so JS can abort work.
  static const String cancelRequestMethod = r'$/cancelRequest';

  final JsonRpcFrameSink _send;
  final Map<Object, _PendingRequest> _pending = HashMap<Object, _PendingRequest>();
  final Map<String, ReactRpcHandler> _handlers = <String, ReactRpcHandler>{};
  final StreamController<JsonRpcNotification> _notifications =
      StreamController<JsonRpcNotification>.broadcast(sync: false);
  int _nextId = 1;
  bool _closed = false;

  /// Whether [close] was called.
  bool get isClosed => _closed;

  /// Number of requests awaiting a response.
  @visibleForTesting
  int get pendingRequestCount => _pending.length;

  /// Notifications received from the peer.
  Stream<JsonRpcNotification> get notifications => _notifications.stream;

  /// Sends a request and completes with the peer's `result`.
  ///
  /// Fails with [ReactRpcTimeoutException], [ReactJsRuntimeException],
  /// [ReactRpcException], [ReactSerializationException] or
  /// [ReactRuntimeDisposedException].
  Future<Object?> request(String method, {Object? params, Duration? timeout}) async {
    _ensureOpen();
    _checkMethodName(method);
    _checkParams(params);
    final int id = _allocateId();
    final String frame = codec.encode(JsonRpcRequest(id: id, method: method, params: params));
    final Duration deadline = timeout ?? defaultTimeout;

    final _PendingRequest pending = _PendingRequest(method);
    _pending[id] = pending;
    pending.timer = Timer(deadline, () {
      if (_pending.remove(id) == null) {
        return;
      }
      pending.completer.completeError(ReactRpcTimeoutException(method, deadline));
      // Best effort: let JS abort the work. Failures here are irrelevant.
      unawaited(notify(cancelRequestMethod, params: <String, Object?>{'id': id}).catchError((Object _) {}));
    });

    try {
      await _send(frame);
    } catch (error, stackTrace) {
      pending.timer?.cancel();
      _pending.remove(id);
      Error.throwWithStackTrace(
        ReactRuntimeDisposedException(runtimeId, reason: 'Failed to deliver "$method": $error'),
        stackTrace,
      );
    }
    return pending.completer.future;
  }

  /// Sends a notification (fire-and-forget event).
  Future<void> notify(String method, {Object? params}) async {
    _ensureOpen();
    _checkMethodName(method);
    _checkParams(params);
    await _send(codec.encode(JsonRpcNotification(method: method, params: params)));
  }

  /// Registers [handler] for requests named [method] coming from JS.
  ///
  /// Throws [StateError] if a handler is already registered for [method].
  ReactHandlerDisposer registerMethod(String method, ReactRpcHandler handler) {
    _ensureOpen();
    _checkMethodName(method);
    if (_handlers.containsKey(method)) {
      throw StateError('A handler for "$method" is already registered');
    }
    _handlers[method] = handler;
    return () {
      if (identical(_handlers[method], handler)) {
        _handlers.remove(method);
      }
    };
  }

  /// Processes one inbound frame. Never throws; problems are answered with
  /// JSON-RPC errors or reported through [onProtocolError].
  Future<void> handleFrame(String frame) async {
    if (_closed) {
      return;
    }
    final JsonRpcDecodeResult decoded = codec.decode(frame);
    for (final JsonRpcFailure reject in decoded.rejects) {
      _reportProtocolError('Rejected inbound frame: ${reject.error.message}');
      await _trySend(reject);
    }
    final List<Future<void>> dispatches = <Future<void>>[];
    for (final JsonRpcMessage message in decoded.messages) {
      switch (message) {
        case JsonRpcSuccess(:final Object id, :final Object? result):
          _resolve(id, (Completer<Object?> c) => c.complete(result));
        case JsonRpcFailure(:final Object? id, :final JsonRpcError error):
          if (id == null) {
            _reportProtocolError('Peer reported an error without id: ${error.message}');
          } else {
            _resolve(id, (Completer<Object?> c) => c.completeError(error.toException()));
          }
        case JsonRpcRequest():
          // Requests run concurrently; a slow handler must not block others.
          dispatches.add(_dispatch(message));
        case JsonRpcNotification():
          if (!_notifications.isClosed) {
            _notifications.add(message);
          }
      }
    }
    await Future.wait(dispatches);
  }

  /// Fails every pending request with [error] without closing the endpoint.
  ///
  /// Used when the runtime reports a fatal JS error but may be restarted.
  void failPending(ReactEmbedException error) {
    final List<_PendingRequest> pending = _pending.values.toList();
    _pending.clear();
    for (final _PendingRequest request in pending) {
      request.timer?.cancel();
      request.completer.completeError(error);
    }
  }

  /// Closes the endpoint, failing pending requests and dropping handlers.
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    failPending(ReactRuntimeDisposedException(runtimeId));
    _handlers.clear();
    await _notifications.close();
  }

  Future<void> _dispatch(JsonRpcRequest request) async {
    final ReactRpcHandler? handler = _handlers[request.method];
    if (handler == null) {
      await _trySend(JsonRpcFailure(
        id: request.id,
        error: JsonRpcError(
          code: JsonRpcErrorCode.methodNotFound,
          message: 'No Dart handler registered for "${request.method}"',
        ),
      ));
      return;
    }

    JsonRpcMessage response;
    try {
      final Object? result = await handler(request.params);
      response = JsonRpcSuccess(id: request.id, result: result);
      // Encode eagerly so a non-JSON result is reported as a handler bug
      // instead of being lost in the transport.
      codec.encode(response);
    } on ReactRpcException catch (e) {
      response = JsonRpcFailure(
        id: request.id,
        error: JsonRpcError(code: e.code, message: e.message, data: e.data),
      );
    } on ReactSerializationException catch (e) {
      response = JsonRpcFailure(
        id: request.id,
        error: JsonRpcError(
          code: JsonRpcErrorCode.internalError,
          message: 'Handler "${request.method}" returned a non-JSON value at ${e.path}',
        ),
      );
    } catch (error, stackTrace) {
      response = JsonRpcFailure(
        id: request.id,
        error: JsonRpcError(
          code: JsonRpcErrorCode.internalError,
          message: 'Handler "${request.method}" threw: $error',
          // Stack traces reveal implementation details; only ship them in debug.
          data: kDebugMode ? <String, Object?>{'dartStack': stackTrace.toString()} : null,
        ),
      );
    }
    await _trySend(response);
  }

  void _resolve(Object id, void Function(Completer<Object?> completer) complete) {
    final _PendingRequest? pending = _pending.remove(id);
    if (pending == null) {
      // Typically a response that arrived after its request timed out.
      _reportProtocolError('Dropped response for unknown or expired request id $id');
      return;
    }
    pending.timer?.cancel();
    complete(pending.completer);
  }

  Future<void> _trySend(JsonRpcMessage message) async {
    if (_closed) {
      return;
    }
    try {
      await _send(codec.encode(message));
    } catch (error) {
      _reportProtocolError('Failed to send ${message.runtimeType}: $error');
    }
  }

  void _reportProtocolError(String message) {
    onProtocolError?.call(ReactProtocolException('[$runtimeId] $message'));
  }

  int _allocateId() {
    final int id = _nextId;
    // Stay inside the JS safe-integer range on very long-lived runtimes.
    _nextId = _nextId >= JsonSafety.maxSafeInteger ? 1 : _nextId + 1;
    return id;
  }

  void _ensureOpen() {
    if (_closed) {
      throw ReactRuntimeDisposedException(runtimeId);
    }
  }

  static void _checkMethodName(String method) {
    if (method.isEmpty) {
      throw const ReactConfigurationException('Method name must not be empty');
    }
    if (method.startsWith('rpc.')) {
      throw ReactConfigurationException('"$method": the "rpc." prefix is reserved by JSON-RPC');
    }
  }

  static void _checkParams(Object? params) {
    if (params != null && params is! Map<String, Object?> && params is! List<Object?>) {
      throw ReactSerializationException(
        'params must be a Map<String, Object?>, a List or null, got ${params.runtimeType}',
        path: r'$.params',
      );
    }
  }
}

final class _PendingRequest {
  _PendingRequest(this.method);

  final String method;
  final Completer<Object?> completer = Completer<Object?>();
  Timer? timer;
}
