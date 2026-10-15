/// Error taxonomy for flutter_react_embed.
///
/// Every failure that crosses the public API is a subtype of the sealed
/// [ReactEmbedException], so callers can `switch` over it exhaustively.
library;

/// Root of every error raised by flutter_react_embed.
sealed class ReactEmbedException implements Exception {
  const ReactEmbedException(this.message, {this.cause});

  /// Human-readable description, safe to log.
  final String message;

  /// The underlying error (for example a `PlatformException`), when one exists.
  final Object? cause;

  @override
  String toString() {
    final String suffix = cause == null ? '' : ' (cause: $cause)';
    return '$runtimeType: $message$suffix';
  }
}

/// The native framework (Hermes/ReactHost or the WebView) failed to start.
///
/// [code] is the platform error code, for example `BUNDLE_NOT_FOUND`,
/// `BUNDLE_INTEGRITY`, `ENGINE_INIT_FAILED` or `UNSUPPORTED_ENGINE`.
final class ReactEngineInitializationException extends ReactEmbedException {
  /// Creates an initialization failure with a platform [code].
  const ReactEngineInitializationException(super.message, {required this.code, super.cause});

  /// Platform-provided error code.
  final String code;
}

/// No implementation is registered for the current platform, or the native
/// side of the plugin is not linked into the host app.
final class ReactEngineUnavailableException extends ReactEmbedException {
  /// Creates an unavailability error.
  const ReactEngineUnavailableException(super.message, {super.cause});
}

/// The runtime was disposed (or crashed) while an operation was pending.
final class ReactRuntimeDisposedException extends ReactEmbedException {
  /// Creates a disposed-runtime error for [runtimeId].
  const ReactRuntimeDisposedException(this.runtimeId, {String? reason})
    : super(reason ?? 'React runtime "$runtimeId" is no longer available');

  /// Id of the runtime that went away.
  final String runtimeId;
}

/// JavaScript threw, either inside an RPC handler or as an uncaught error.
final class ReactJsRuntimeException extends ReactEmbedException {
  /// Creates a JS-side exception.
  const ReactJsRuntimeException(super.message, {this.jsStack, this.isFatal = false, super.cause});

  /// The JS stack trace as reported by the runtime (source-mapped in debug).
  final String? jsStack;

  /// Whether the runtime is unusable after this error.
  final bool isFatal;
}

/// The remote peer answered a request with a JSON-RPC error object.
final class ReactRpcException extends ReactEmbedException {
  /// Creates an RPC error. Dart handlers may throw this to choose the code
  /// sent back to JavaScript (for example `invalidParams`).
  const ReactRpcException(super.message, {required this.code, this.data});

  /// JSON-RPC error code (see `JsonRpcErrorCode`).
  final int code;

  /// Optional structured error payload; must be JSON-encodable.
  final Object? data;
}

/// A request did not receive a response before its deadline.
final class ReactRpcTimeoutException extends ReactEmbedException {
  /// Creates a timeout error for [method].
  ReactRpcTimeoutException(this.method, this.timeout)
    : super('RPC "$method" timed out after ${timeout.inMilliseconds} ms');

  /// The method that timed out.
  final String method;

  /// The timeout that elapsed.
  final Duration timeout;
}

/// A Dart value could not be represented as JSON for the bridge.
final class ReactSerializationException extends ReactEmbedException {
  /// Creates a serialization error located at JSON [path] (for example
  /// `$.items[2].createdAt`).
  const ReactSerializationException(super.message, {required this.path});

  /// JSONPath-style location of the offending value.
  final String path;
}

/// A peer sent a frame that violates the bridge protocol.
final class ReactProtocolException extends ReactEmbedException {
  /// Creates a protocol violation error.
  const ReactProtocolException(super.message, {super.cause});
}

/// A `ReactView` or engine configuration is invalid for this environment.
final class ReactConfigurationException extends ReactEmbedException {
  /// Creates a configuration error.
  const ReactConfigurationException(super.message);
}
