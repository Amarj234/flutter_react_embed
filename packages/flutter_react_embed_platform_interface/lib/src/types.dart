/// Value types shared by the platform contract and its implementations.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'errors.dart';
import 'json_rpc.dart';

/// A JSON object as exchanged with JavaScript.
typedef JsonMap = Map<String, Object?>;

/// Serves a JSON-RPC request issued by JavaScript.
///
/// [params] is a [JsonMap], a `List<Object?>` or `null`, exactly as JS sent
/// it. The return value must be JSON-encodable. Throw [ReactRpcException] to
/// choose the error code JavaScript receives; any other exception becomes an
/// `internalError`.
typedef ReactRpcHandler = FutureOr<Object?> Function(Object? params);

/// Removes a registration made with `registerHandler`.
typedef ReactHandlerDisposer = void Function();

/// Which JavaScript engine hosts a micro-frontend.
enum ReactEngineKind {
  /// Hermes + Fabric surfaces composited as platform views.
  reactNative('react_native'),

  /// A production React SPA rendered by a plugin-owned WebView.
  web('web');

  const ReactEngineKind(this.wireName);

  /// Identifier used on the platform channel.
  final String wireName;

  /// Platform view type registered by the native implementation.
  String get viewType => 'dev.flutter_react_embed/view/$wireName';
}

/// Lifecycle of a JavaScript runtime.
enum ReactRuntimeState {
  /// Runtime is booting; the bundle is not yet evaluated.
  initializing,

  /// Bundle evaluated and the bridge handshake completed.
  ready,

  /// Surfaces are stopped (app backgrounded); the runtime stays resident.
  paused,

  /// The JS runtime or WebView renderer process died.
  crashed,

  /// Runtime released; every operation on it fails.
  disposed;

  /// Parses a state reported by native code.
  ///
  /// Throws [ReactProtocolException] for unknown values instead of guessing.
  static ReactRuntimeState fromWire(String value) {
    for (final ReactRuntimeState state in values) {
      if (state.name == value) {
        return state;
      }
    }
    throw ReactProtocolException('Unknown runtime state "$value"');
  }
}

/// Configuration for booting one JavaScript runtime.
@immutable
final class ReactEngineConfig {
  /// Creates an engine configuration.
  ///
  /// [bundle] is a Flutter asset key: the `.hbc` bundle for
  /// [ReactEngineKind.reactNative], or the SPA root directory (containing
  /// `index.html`) for [ReactEngineKind.web].
  const ReactEngineConfig({
    required this.engine,
    required this.bundle,
    this.bundleSha256,
    this.contractVersion = '1.0.0',
    this.enableDebugging = false,
    this.requestTimeout = const Duration(seconds: 10),
    this.maxMessageBytes = 1024 * 1024,
  });

  /// Engine that hosts the bundle.
  final ReactEngineKind engine;

  /// Flutter asset key of the bundle.
  final String bundle;

  /// Expected sha256 of the bundle; native code refuses to boot on mismatch.
  final String? bundleSha256;

  /// Bridge contract version the bundle was built against.
  final String contractVersion;

  /// Enables the Hermes inspector or WebView remote debugging.
  final bool enableDebugging;

  /// Default deadline for Dart to JS requests.
  final Duration requestTimeout;

  /// Upper bound for one encoded frame, in UTF-8 bytes.
  final int maxMessageBytes;

  /// Validates the configuration, throwing [ReactConfigurationException].
  void validate() {
    if (bundle.trim().isEmpty) {
      throw const ReactConfigurationException('bundle must not be empty');
    }
    if (requestTimeout <= Duration.zero) {
      throw const ReactConfigurationException('requestTimeout must be > 0');
    }
    if (maxMessageBytes < 1024) {
      throw const ReactConfigurationException('maxMessageBytes must be >= 1024');
    }
    final String? sha = bundleSha256;
    if (sha != null && !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha)) {
      throw const ReactConfigurationException(
        'bundleSha256 must be 64 hexadecimal characters',
      );
    }
  }

  /// Encodes the configuration for the control channel.
  JsonMap toWire() => <String, Object?>{
        'engine': engine.wireName,
        'bundle': bundle,
        'bundleSha256': bundleSha256,
        'contractVersion': contractVersion,
        'enableDebugging': enableDebugging,
        'maxMessageBytes': maxMessageBytes,
      };

  @override
  bool operator ==(Object other) =>
      other is ReactEngineConfig &&
      other.engine == engine &&
      other.bundle == bundle &&
      other.bundleSha256 == bundleSha256 &&
      other.contractVersion == contractVersion &&
      other.enableDebugging == enableDebugging &&
      other.requestTimeout == requestTimeout &&
      other.maxMessageBytes == maxMessageBytes;

  @override
  int get hashCode => Object.hash(
        engine,
        bundle,
        bundleSha256,
        contractVersion,
        enableDebugging,
        requestTimeout,
        maxMessageBytes,
      );
}

/// Opaque reference to a booted runtime.
@immutable
final class ReactRuntimeHandle {
  /// Creates a handle. Only platform implementations should call this.
  const ReactRuntimeHandle({required this.id, required this.engine});

  /// Native runtime id.
  final String id;

  /// Engine that backs the runtime.
  final ReactEngineKind engine;

  @override
  bool operator ==(Object other) => other is ReactRuntimeHandle && other.id == id && other.engine == engine;

  @override
  int get hashCode => Object.hash(id, engine);

  @override
  String toString() => 'ReactRuntimeHandle(${engine.wireName}:$id)';
}

/// Parameters the native platform view factory needs to attach a React root.
@immutable
final class ReactSurfaceCreationParams {
  /// Creates surface creation parameters.
  const ReactSurfaceCreationParams({
    required this.runtime,
    required this.moduleName,
    this.initialProps = const <String, Object?>{},
    this.cacheKey,
  });

  /// Runtime the surface renders in.
  final ReactRuntimeHandle runtime;

  /// Registered React root component (`AppRegistry` name) or SPA route.
  final String moduleName;

  /// Props for the first render. Must be JSON-encodable.
  final JsonMap initialProps;

  /// When set, native code reattaches a retained surface with this key
  /// instead of rendering a new one (see `ReactSurfaceCache`).
  final String? cacheKey;

  /// Encodes the params for `StandardMessageCodec`.
  ///
  /// Props travel as a JSON string so native code forwards them to JS without
  /// re-encoding. Throws [ReactSerializationException] for non-JSON props.
  Map<String, Object?> toCreationParams() {
    if (moduleName.trim().isEmpty) {
      throw const ReactConfigurationException('moduleName must not be empty');
    }
    return <String, Object?>{
      'runtimeId': runtime.id,
      'engine': runtime.engine.wireName,
      'moduleName': moduleName,
      'initialPropsJson': JsonSafety.encode(initialProps, path: r'$.initialProps'),
      'cacheKey': cacheKey,
    };
  }
}

/// A notification sent by JavaScript.
@immutable
final class ReactBridgeEvent {
  /// Creates an event.
  const ReactBridgeEvent({
    required this.runtime,
    required this.name,
    this.data,
  });

  /// Runtime that emitted the event.
  final ReactRuntimeHandle runtime;

  /// Event name (the JSON-RPC notification method).
  final String name;

  /// Decoded JSON payload.
  final Object? data;

  @override
  String toString() => 'ReactBridgeEvent($name from ${runtime.id})';
}

/// An uncaught JavaScript error reported by the runtime.
@immutable
final class ReactRuntimeError {
  /// Creates a runtime error report.
  const ReactRuntimeError({
    required this.runtime,
    required this.message,
    this.jsStack,
    this.isFatal = false,
  });

  /// Runtime that failed.
  final ReactRuntimeHandle runtime;

  /// Error message.
  final String message;

  /// JS stack trace, if available.
  final String? jsStack;

  /// Whether the runtime is unusable after this error.
  final bool isFatal;

  /// Converts the report to a throwable [ReactJsRuntimeException].
  ReactJsRuntimeException toException() => ReactJsRuntimeException(message, jsStack: jsStack, isFatal: isFatal);
}
