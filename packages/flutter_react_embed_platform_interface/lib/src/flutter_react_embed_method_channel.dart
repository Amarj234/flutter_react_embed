/// Default [FlutterReactEmbedPlatform] implementation over MethodChannels.
///
/// Two channels are used:
///
/// * `dev.flutter_react_embed/control`: lifecycle (initializeEngine,
///   disposeEngine, updateProps, evictCachedSurface). Low frequency.
/// * `dev.flutter_react_embed/messages`: JSON-RPC frames in both directions,
///   plus runtime state and error notifications from native code.
///
/// Frames are JSON strings. Native code forwards them to JavaScript verbatim,
/// so validation and encoding happen exactly once, in Dart and in the JS
/// bridge package, and never in Kotlin or Swift.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../flutter_react_embed_platform_interface.dart';

/// [FlutterReactEmbedPlatform] backed by MethodChannels.
class MethodChannelFlutterReactEmbed extends FlutterReactEmbedPlatform {
  /// Creates the implementation. Tests may inject channels.
  MethodChannelFlutterReactEmbed({MethodChannel? controlChannel, MethodChannel? messageChannel})
    : controlChannel = controlChannel ?? const MethodChannel(controlChannelName),
      messageChannel = messageChannel ?? const MethodChannel(messageChannelName);

  /// Name of the lifecycle channel.
  static const String controlChannelName = 'dev.flutter_react_embed/control';

  /// Name of the JSON-RPC frame channel.
  static const String messageChannelName = 'dev.flutter_react_embed/messages';

  /// Frames buffered per runtime id that native delivered before
  /// [initializeEngine] returned (for example the JS `hello` notification).
  static const int maxBufferedFramesPerRuntime = 64;

  /// Distinct unknown runtime ids buffered at once; the oldest is dropped.
  static const int maxBufferedRuntimes = 8;

  /// Lifecycle channel.
  @visibleForTesting
  final MethodChannel controlChannel;

  /// Frame channel.
  @visibleForTesting
  final MethodChannel messageChannel;

  final Map<String, _RuntimeSession> _sessions = <String, _RuntimeSession>{};
  final LinkedHashMap<String, List<String>> _earlyFrames = LinkedHashMap<String, List<String>>();
  bool _inboundHandlerInstalled = false;

  @override
  Future<ReactRuntimeHandle> initializeEngine(ReactEngineConfig config) async {
    config.validate();
    _ensureInboundHandler();

    final Map<String, Object?>? reply;
    try {
      reply = await controlChannel.invokeMapMethod<String, Object?>('initializeEngine', config.toWire());
    } on MissingPluginException catch (e) {
      throw ReactEngineUnavailableException(
        'flutter_react_embed has no native implementation on this platform, '
        'or the plugin is not registered with the host engine',
        cause: e,
      );
    } on PlatformException catch (e) {
      throw ReactEngineInitializationException(
        e.message ?? 'Native engine failed to initialize',
        code: e.code,
        cause: e,
      );
    }

    final Object? runtimeId = reply?['runtimeId'];
    if (runtimeId is! String || runtimeId.isEmpty) {
      throw ReactEngineInitializationException(
        'initializeEngine returned no runtimeId (reply: $reply)',
        code: 'MALFORMED_REPLY',
      );
    }
    if (_sessions.containsKey(runtimeId)) {
      throw ReactEngineInitializationException(
        'Native code reused live runtime id "$runtimeId"',
        code: 'DUPLICATE_RUNTIME',
      );
    }

    final ReactRuntimeHandle handle = ReactRuntimeHandle(id: runtimeId, engine: config.engine);
    final _RuntimeSession session = _RuntimeSession(
      handle: handle,
      endpoint: JsonRpcEndpoint(
        runtimeId: runtimeId,
        codec: JsonRpcCodec(maxMessageBytes: config.maxMessageBytes),
        defaultTimeout: config.requestTimeout,
        send: (String frame) => _deliver(runtimeId, frame),
        onProtocolError: _reportProtocolError,
      ),
    );
    _sessions[runtimeId] = session;

    final List<String>? early = _earlyFrames.remove(runtimeId);
    if (early != null) {
      for (final String frame in early) {
        unawaited(session.endpoint.handleFrame(frame));
      }
    }
    return handle;
  }

  @override
  Future<void> disposeEngine(ReactRuntimeHandle runtime) async {
    final _RuntimeSession? session = _sessions.remove(runtime.id);
    _earlyFrames.remove(runtime.id);
    if (session == null) {
      return;
    }
    // Local teardown first: pending callers must not wait on native code.
    await session.close();
    try {
      await controlChannel.invokeMethod<void>('disposeEngine', <String, Object?>{'runtimeId': runtime.id});
    } on MissingPluginException {
      // Nothing native to release.
    } on PlatformException catch (e, stackTrace) {
      // Disposal is best effort and must not throw into widget teardown.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: stackTrace,
          library: 'flutter_react_embed',
          context: ErrorDescription('while disposing React runtime ${runtime.id}'),
        ),
      );
    }
  }

  @override
  Future<void> updateProps(int viewId, JsonMap props) async {
    final String propsJson = JsonSafety.encode(props, path: r'$.props');
    await _guard(
      'updateProps',
      () =>
          controlChannel.invokeMethod<void>('updateProps', <String, Object?>{'viewId': viewId, 'propsJson': propsJson}),
    );
  }

  @override
  Future<Object?> invoke(ReactRuntimeHandle runtime, String method, {Object? params, Duration? timeout}) {
    return _session(runtime).endpoint.request(method, params: params, timeout: timeout);
  }

  @override
  Future<void> emit(ReactRuntimeHandle runtime, String name, {Object? data}) {
    return _session(runtime).endpoint.notify(name, params: _wrapEventData(data));
  }

  @override
  ReactHandlerDisposer registerHandler(ReactRuntimeHandle runtime, String method, ReactRpcHandler handler) {
    return _session(runtime).endpoint.registerMethod(method, handler);
  }

  @override
  Stream<ReactBridgeEvent> events(ReactRuntimeHandle runtime, {String? name}) {
    final Stream<ReactBridgeEvent> all = _session(runtime).events;
    return name == null ? all : all.where((ReactBridgeEvent e) => e.name == name);
  }

  @override
  Stream<ReactRuntimeState> runtimeStates(ReactRuntimeHandle runtime) => _session(runtime).states.stream;

  @override
  Stream<ReactRuntimeError> runtimeErrors(ReactRuntimeHandle runtime) => _session(runtime).errors.stream;

  @override
  Future<void> evictCachedSurface(String cacheKey) async {
    try {
      await controlChannel.invokeMethod<void>('evictCachedSurface', <String, Object?>{'cacheKey': cacheKey});
    } on MissingPluginException {
      // No native cache to evict.
    } on PlatformException catch (e) {
      throw ReactProtocolException('evictCachedSurface failed: ${e.message}', cause: e);
    }
  }

  /// Number of live runtime sessions.
  @visibleForTesting
  int get liveSessionCount => _sessions.length;

  // ---------------------------------------------------------------------------
  // Inbound (native -> Dart)
  // ---------------------------------------------------------------------------

  void _ensureInboundHandler() {
    if (_inboundHandlerInstalled) {
      return;
    }
    messageChannel.setMethodCallHandler(_onNativeCall);
    _inboundHandlerInstalled = true;
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    final Map<Object?, Object?> args = _argumentsOf(call);
    final String runtimeId = _requireString(args, 'runtimeId', call.method);
    final _RuntimeSession? session = _sessions[runtimeId];

    switch (call.method) {
      case 'onFrame':
        final String frame = _requireString(args, 'frame', call.method);
        if (session == null) {
          _bufferEarlyFrame(runtimeId, frame);
        } else {
          // Reply to native immediately; handlers may be slow.
          unawaited(session.endpoint.handleFrame(frame));
        }
        return null;

      case 'onRuntimeState':
        final ReactRuntimeState state = ReactRuntimeState.fromWire(_requireString(args, 'state', call.method));
        if (session == null) {
          return null;
        }
        session.setState(state);
        if (state == ReactRuntimeState.disposed) {
          _sessions.remove(runtimeId);
          await session.close();
        }
        return null;

      case 'onRuntimeError':
        if (session == null) {
          return null;
        }
        final Object? stack = args['stack'];
        final Object? fatal = args['fatal'];
        final ReactRuntimeError error = ReactRuntimeError(
          runtime: session.handle,
          message: _requireString(args, 'message', call.method),
          jsStack: stack is String ? stack : null,
          isFatal: fatal is bool && fatal,
        );
        session.reportError(error);
        return null;

      default:
        throw MissingPluginException('Unknown inbound method ${call.method}');
    }
  }

  void _bufferEarlyFrame(String runtimeId, String frame) {
    final List<String> frames = _earlyFrames.putIfAbsent(runtimeId, () => <String>[]);
    if (frames.length >= maxBufferedFramesPerRuntime) {
      _reportProtocolError(ReactProtocolException('[$runtimeId] Early frame buffer full; dropping frame'));
      return;
    }
    frames.add(frame);
    while (_earlyFrames.length > maxBufferedRuntimes) {
      final String evicted = _earlyFrames.keys.first;
      _earlyFrames.remove(evicted);
      _reportProtocolError(ReactProtocolException('Dropped buffered frames for unknown runtime "$evicted"'));
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<void> _deliver(String runtimeId, String frame) async {
    try {
      await messageChannel.invokeMethod<void>('deliver', <String, Object?>{'runtimeId': runtimeId, 'frame': frame});
    } on MissingPluginException catch (e) {
      throw ReactEngineUnavailableException('Native frame channel is not available', cause: e);
    } on PlatformException catch (e) {
      throw ReactRuntimeDisposedException(runtimeId, reason: e.message);
    }
  }

  _RuntimeSession _session(ReactRuntimeHandle runtime) {
    final _RuntimeSession? session = _sessions[runtime.id];
    if (session == null) {
      throw ReactRuntimeDisposedException(runtime.id);
    }
    return session;
  }

  static Future<void> _guard(String operation, Future<void> Function() body) async {
    try {
      await body();
    } on MissingPluginException catch (e) {
      throw ReactEngineUnavailableException('$operation is not available', cause: e);
    } on PlatformException catch (e) {
      throw ReactProtocolException('$operation failed: ${e.message ?? e.code}', cause: e);
    }
  }

  /// Notifications carry `params` as an object; wrap scalars and lists.
  static Object? _wrapEventData(Object? data) => switch (data) {
    null => null,
    Map<String, Object?>() => data,
    _ => <String, Object?>{'value': data},
  };

  static Map<Object?, Object?> _argumentsOf(MethodCall call) {
    final Object? arguments = call.arguments;
    if (arguments is! Map<Object?, Object?>) {
      throw PlatformException(
        code: 'INVALID_ARGUMENTS',
        message: '${call.method} expects a map, got ${arguments.runtimeType}',
      );
    }
    return arguments;
  }

  static String _requireString(Map<Object?, Object?> args, String key, String method) {
    final Object? value = args[key];
    if (value is! String) {
      throw PlatformException(code: 'INVALID_ARGUMENTS', message: '$method requires a String "$key"');
    }
    return value;
  }

  static void _reportProtocolError(ReactProtocolException error) {
    FlutterError.reportError(
      FlutterErrorDetails(exception: error, library: 'flutter_react_embed', silent: !kDebugMode),
    );
  }
}

/// Per-runtime state: the JSON-RPC endpoint and lifecycle streams.
final class _RuntimeSession {
  _RuntimeSession({required this.handle, required this.endpoint}) {
    _events = StreamController<ReactBridgeEvent>.broadcast(onListen: _flushBacklog);
    _notificationSubscription = endpoint.notifications
        // `$/` methods are protocol-level (e.g. cancellation), not events.
        .where((JsonRpcNotification n) => !n.method.startsWith(r'$/'))
        .listen(_onNotification);
  }

  /// Events received before anyone listened (e.g. the JS `hello` sent while
  /// the runtime booted) are kept for the first listener, up to this many.
  static const int maxBacklog = 64;

  final ReactRuntimeHandle handle;
  final JsonRpcEndpoint endpoint;
  late final StreamController<ReactBridgeEvent> _events;
  late final StreamSubscription<JsonRpcNotification> _notificationSubscription;
  final ListQueue<ReactBridgeEvent> _backlog = ListQueue<ReactBridgeEvent>();
  final StreamController<ReactRuntimeState> states = StreamController<ReactRuntimeState>.broadcast();
  final StreamController<ReactRuntimeError> errors = StreamController<ReactRuntimeError>.broadcast();
  ReactRuntimeState _state = ReactRuntimeState.initializing;

  /// Bridge events; the first listener also receives the backlog.
  Stream<ReactBridgeEvent> get events => _events.stream;

  void _onNotification(JsonRpcNotification n) {
    final ReactBridgeEvent event = ReactBridgeEvent(runtime: handle, name: n.method, data: n.params);
    if (_events.hasListener) {
      _events.add(event);
      return;
    }
    if (_backlog.length == maxBacklog) {
      _backlog.removeFirst();
    }
    _backlog.add(event);
  }

  void _flushBacklog() {
    while (_backlog.isNotEmpty && !_events.isClosed) {
      _events.add(_backlog.removeFirst());
    }
  }

  void setState(ReactRuntimeState state) {
    if (state == _state || states.isClosed) {
      return;
    }
    _state = state;
    states.add(state);
    if (state == ReactRuntimeState.crashed) {
      endpoint.failPending(ReactJsRuntimeException('React runtime ${handle.id} crashed', isFatal: true));
    }
  }

  void reportError(ReactRuntimeError error) {
    if (!errors.isClosed) {
      errors.add(error);
    }
    if (error.isFatal) {
      endpoint.failPending(error.toException());
      setState(ReactRuntimeState.crashed);
    }
  }

  Future<void> close() async {
    setState(ReactRuntimeState.disposed);
    await _notificationSubscription.cancel();
    await endpoint.close();
    _backlog.clear();
    await _events.close();
    await states.close();
    await errors.close();
  }
}
