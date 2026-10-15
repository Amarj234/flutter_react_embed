/// Federated platform contract for flutter_react_embed.
///
/// Platform implementations (`flutter_react_embed_android`,
/// `flutter_react_embed_ios`, `flutter_react_embed_web`) extend
/// [FlutterReactEmbedPlatform] and assign themselves to
/// [FlutterReactEmbedPlatform.instance] during plugin registration. Until one
/// does, [MethodChannelFlutterReactEmbed] is used.
library;

import 'dart:async';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'src/errors.dart';
import 'src/flutter_react_embed_method_channel.dart';
import 'src/types.dart';

export 'src/errors.dart';
export 'src/flutter_react_embed_method_channel.dart' show MethodChannelFlutterReactEmbed;
export 'src/json_rpc.dart'
    show
        JsonRpcCodec,
        JsonRpcDecodeResult,
        JsonRpcEndpoint,
        JsonRpcError,
        JsonRpcErrorCode,
        JsonRpcFailure,
        JsonRpcMessage,
        JsonRpcNotification,
        JsonRpcRequest,
        JsonRpcSuccess,
        JsonSafety;
export 'src/types.dart';

/// The contract every flutter_react_embed platform implementation fulfils.
///
/// The contract covers four concerns:
///
/// * **Engine context**: [initializeEngine] boots a JavaScript runtime
///   (Hermes, or a WebView document) and [disposeEngine] releases it.
/// * **Properties**: initial props travel with the platform view's creation
///   params ([ReactSurfaceCreationParams]); [updateProps] re-renders a mounted
///   surface.
/// * **Messaging**: [invoke] and [emit] send JSON-RPC requests and
///   notifications to JavaScript; [registerHandler] serves requests from
///   JavaScript; [events] delivers JavaScript notifications.
/// * **Health**: [runtimeStates] and [runtimeErrors] report lifecycle changes
///   and uncaught JavaScript errors.
///
/// Every method fails with a [ReactEmbedException] subtype, never with a raw
/// `PlatformException`.
abstract class FlutterReactEmbedPlatform extends PlatformInterface {
  /// Constructs a platform implementation.
  FlutterReactEmbedPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterReactEmbedPlatform _instance = MethodChannelFlutterReactEmbed();

  /// The active implementation.
  static FlutterReactEmbedPlatform get instance => _instance;

  /// Replaces the active implementation.
  ///
  /// Implementations must extend [FlutterReactEmbedPlatform] (not implement
  /// it), which the token check enforces.
  static set instance(FlutterReactEmbedPlatform instance) {
    PlatformInterface.verify(instance, _token);
    _instance = instance;
  }

  /// Platform view type that renders surfaces for [engine].
  String viewTypeFor(ReactEngineKind engine) => engine.viewType;

  /// Boots a JavaScript runtime for [config] and completes once its bridge
  /// handshake has finished.
  ///
  /// Throws [ReactConfigurationException] for an invalid [config],
  /// [ReactEngineInitializationException] when the native framework fails to
  /// start, and [ReactEngineUnavailableException] when no native
  /// implementation is linked.
  Future<ReactRuntimeHandle> initializeEngine(ReactEngineConfig config) {
    throw UnimplementedError('initializeEngine() has not been implemented.');
  }

  /// Releases [runtime] and every surface rendered by it.
  ///
  /// Idempotent: disposing an already disposed runtime completes normally.
  /// Pending requests fail with [ReactRuntimeDisposedException].
  Future<void> disposeEngine(ReactRuntimeHandle runtime) {
    throw UnimplementedError('disposeEngine() has not been implemented.');
  }

  /// Replaces the props of the surface hosted by platform view [viewId].
  ///
  /// [props] must be JSON-encodable ([ReactSerializationException]).
  Future<void> updateProps(int viewId, JsonMap props) {
    throw UnimplementedError('updateProps() has not been implemented.');
  }

  /// Calls the JavaScript method [method] and returns its decoded result.
  ///
  /// [params] must be a [JsonMap], a `List<Object?>` or `null`. When
  /// [timeout] is omitted, [ReactEngineConfig.requestTimeout] applies.
  Future<Object?> invoke(ReactRuntimeHandle runtime, String method, {Object? params, Duration? timeout}) {
    throw UnimplementedError('invoke() has not been implemented.');
  }

  /// Sends the event [name] with optional [data] to JavaScript.
  ///
  /// Completes when the frame is handed to the transport; there is no
  /// acknowledgement from JavaScript.
  Future<void> emit(ReactRuntimeHandle runtime, String name, {Object? data}) {
    throw UnimplementedError('emit() has not been implemented.');
  }

  /// Serves JavaScript requests named [method] with [handler].
  ///
  /// Returns a disposer that unregisters the handler. Throws [StateError] if
  /// [method] already has a handler on [runtime].
  ReactHandlerDisposer registerHandler(ReactRuntimeHandle runtime, String method, ReactRpcHandler handler) {
    throw UnimplementedError('registerHandler() has not been implemented.');
  }

  /// Broadcast stream of events emitted by JavaScript on [runtime].
  ///
  /// When [name] is set, only events with that name are delivered. The stream
  /// closes when the runtime is disposed.
  Stream<ReactBridgeEvent> events(ReactRuntimeHandle runtime, {String? name}) {
    throw UnimplementedError('events() has not been implemented.');
  }

  /// Broadcast stream of lifecycle changes for [runtime].
  Stream<ReactRuntimeState> runtimeStates(ReactRuntimeHandle runtime) {
    throw UnimplementedError('runtimeStates() has not been implemented.');
  }

  /// Broadcast stream of uncaught JavaScript errors on [runtime].
  Stream<ReactRuntimeError> runtimeErrors(ReactRuntimeHandle runtime) {
    throw UnimplementedError('runtimeErrors() has not been implemented.');
  }

  /// Drops the retained native surface (and its texture) stored under
  /// [cacheKey]. Completes normally if nothing is cached under that key.
  Future<void> evictCachedSurface(String cacheKey) {
    throw UnimplementedError('evictCachedSurface() has not been implemented.');
  }
}
