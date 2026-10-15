import 'dart:async';

import 'package:flutter_react_embed_platform_interface/flutter_react_embed_platform_interface.dart';

/// Talks to the React root rendered by one mounted `ReactView`.
///
/// Obtained from `ReactView.onViewCreated`. The controller is invalidated
/// when its view is disposed or reconfigured; later calls fail with
/// [ReactRuntimeDisposedException].
final class ReactViewController {
  /// Creates a controller. Called by `ReactView`; not part of the stable API.
  ReactViewController.internal({
    required this.runtime,
    required this.viewId,
    required this._platform,
  });

  /// Runtime rendering this view.
  final ReactRuntimeHandle runtime;

  /// Platform view id of the hosting native view.
  final int viewId;

  final FlutterReactEmbedPlatform _platform;
  final List<ReactHandlerDisposer> _disposers = <ReactHandlerDisposer>[];
  bool _disposed = false;

  /// Whether the owning view has been disposed or reconfigured.
  bool get isDisposed => _disposed;

  /// Replaces the React root's props.
  Future<void> updateProps(JsonMap props) {
    _ensureActive();
    return _platform.updateProps(viewId, props);
  }

  /// Calls the JavaScript method [method] and casts its result to [T].
  ///
  /// Throws [ReactProtocolException] if JavaScript returned a value that is
  /// not a [T] (JSON objects arrive as `Map<String, Object?>`, arrays as
  /// `List<Object?>`, numbers as `int` or `double`).
  Future<T> invoke<T>(String method, {Object? params, Duration? timeout}) async {
    _ensureActive();
    final Object? result = await _platform.invoke(runtime, method, params: params, timeout: timeout);
    if (result is T) {
      return result;
    }
    throw ReactProtocolException('JS method "$method" returned ${result.runtimeType}, expected $T');
  }

  /// Sends the event [name] to JavaScript.
  Future<void> emit(String name, [Object? data]) {
    _ensureActive();
    return _platform.emit(runtime, name, data: data);
  }

  /// Events emitted by JavaScript, optionally filtered by [name].
  Stream<ReactBridgeEvent> events({String? name}) {
    _ensureActive();
    return _platform.events(runtime, name: name);
  }

  /// Serves requests from JavaScript named [method].
  ///
  /// The registration is removed automatically when the controller is
  /// invalidated; the returned disposer removes it earlier.
  ReactHandlerDisposer registerHandler(String method, ReactRpcHandler handler) {
    _ensureActive();
    final ReactHandlerDisposer disposer = _platform.registerHandler(runtime, method, handler);
    _disposers.add(disposer);
    return () {
      if (_disposers.remove(disposer)) {
        disposer();
      }
    };
  }

  /// Invalidates the controller and removes its handler registrations.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final ReactHandlerDisposer disposer in _disposers) {
      disposer();
    }
    _disposers.clear();
  }

  void _ensureActive() {
    if (_disposed) {
      throw ReactRuntimeDisposedException(runtime.id, reason: 'ReactViewController was disposed');
    }
  }
}
