import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_react_embed_platform_interface/flutter_react_embed_platform_interface.dart';

import 'react_surface_cache.dart';
import 'react_view_controller.dart';

const DeepCollectionEquality _deepEquality = DeepCollectionEquality();

/// Where the Flutter app is executing, as far as platform views are concerned.
enum ReactExecutionEnvironment {
  /// Android: `PlatformViewLink` with texture-layer or hybrid composition.
  android,

  /// iOS: `UiKitView` (always hybrid composited).
  ios,

  /// Flutter web: `HtmlElementView` backed by an iframe.
  web,

  /// Any other target (desktop, Fuchsia). Not supported.
  unsupported;

  /// Resolves the current environment.
  ///
  /// Uses [defaultTargetPlatform], so widget tests can select a platform with
  /// `debugDefaultTargetPlatformOverride`.
  static ReactExecutionEnvironment resolve() {
    if (kIsWeb) {
      return ReactExecutionEnvironment.web;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => ReactExecutionEnvironment.android,
      TargetPlatform.iOS => ReactExecutionEnvironment.ios,
      _ => ReactExecutionEnvironment.unsupported,
    };
  }

  /// Whether [engine] can run in this environment. Flutter web cannot host
  /// React Native, which needs a native JS runtime.
  bool supports(ReactEngineKind engine) => switch (this) {
    ReactExecutionEnvironment.android || ReactExecutionEnvironment.ios => true,
    ReactExecutionEnvironment.web => engine == ReactEngineKind.web,
    ReactExecutionEnvironment.unsupported => false,
  };
}

/// How an Android platform view is composited into the Flutter scene.
enum AndroidCompositionMode {
  /// Texture-layer hybrid composition, falling back to hybrid composition
  /// when the view tree needs it. Best scrolling performance; the default.
  textureLayer,

  /// Hybrid composition. Use when the React tree contains `SurfaceView` or
  /// `TextureView` content (video, maps) that texture-layer cannot capture.
  hybrid,
}

/// Declarative configuration of one embedded React micro-frontend.
@immutable
final class ReactViewConfiguration {
  /// Creates a configuration.
  const ReactViewConfiguration({
    required this.engine,
    required this.moduleName,
    this.initialProps = const <String, Object?>{},
    this.cacheKey,
    this.androidComposition = AndroidCompositionMode.textureLayer,
    this.hitTestBehavior = PlatformViewHitTestBehavior.opaque,
  });

  /// Configures a React web build ([ReactEmbedType.web]).
  ///
  /// [assetPath] is the Flutter asset directory holding the build's
  /// `index.html`. [route] is the initial route: `'/path'` for history routing,
  /// `'#/path'` for hash routing.
  factory ReactViewConfiguration.web({
    required String assetPath,
    String route = '/',
    JsonMap initialProps = const <String, Object?>{},
    String? bundleSha256,
    String? cacheKey,
    bool enableDebugging = false,
    Duration requestTimeout = const Duration(seconds: 10),
    AndroidCompositionMode androidComposition = AndroidCompositionMode.textureLayer,
    PlatformViewHitTestBehavior hitTestBehavior = PlatformViewHitTestBehavior.opaque,
  }) => ReactViewConfiguration(
    engine: ReactEngineConfig(
      engine: ReactEngineKind.web,
      bundle: assetPath,
      bundleSha256: bundleSha256,
      enableDebugging: enableDebugging,
      requestTimeout: requestTimeout,
    ),
    moduleName: route,
    initialProps: initialProps,
    cacheKey: cacheKey,
    androidComposition: androidComposition,
    hitTestBehavior: hitTestBehavior,
  );

  /// Configures a React Native app ([ReactEmbedType.native]).
  ///
  /// [bundleName] is the Flutter asset key of the compiled bundle
  /// (`index.android.bundle`). On iOS [iosBundleName] is used instead when set
  /// (`main.jsbundle`). [componentName] is the root component registered with
  /// `AppRegistry.registerComponent`, which receives [initialProps].
  ///
  /// When the host app provides its own React Native host (a
  /// `ReactApplication` on Android, a `FlutterReactEmbedReactNativeHost` on
  /// iOS), that host's bundle is loaded and the bundle names are only checked
  /// for existence.
  factory ReactViewConfiguration.native({
    required String bundleName,
    String? iosBundleName,
    required String componentName,
    JsonMap initialProps = const <String, Object?>{},
    String? bundleSha256,
    String? cacheKey,
    Duration requestTimeout = const Duration(seconds: 10),
    AndroidCompositionMode androidComposition = AndroidCompositionMode.textureLayer,
    PlatformViewHitTestBehavior hitTestBehavior = PlatformViewHitTestBehavior.opaque,
  }) => ReactViewConfiguration(
    engine: ReactEngineConfig(
      engine: ReactEngineKind.reactNative,
      bundle: defaultTargetPlatform == TargetPlatform.iOS ? iosBundleName ?? bundleName : bundleName,
      bundleSha256: bundleSha256,
      requestTimeout: requestTimeout,
    ),
    moduleName: componentName,
    initialProps: initialProps,
    cacheKey: cacheKey,
    androidComposition: androidComposition,
    hitTestBehavior: hitTestBehavior,
  );

  /// Reads a configuration from loosely typed attributes, such as a remote
  /// micro-frontend manifest.
  ///
  /// Recognised keys: `engine` (`react_native` | `web`) or its alias `type`
  /// (`native` | `web`), `bundle` (alias `bundleName`), `bundleSha256`,
  /// `moduleName` (alias `componentName`), `initialProps` (object),
  /// `cacheKey`, `androidComposition` (`textureLayer` | `hybrid`),
  /// `requestTimeoutMs`, `enableDebugging`. Throws
  /// [ReactConfigurationException] on a missing, mistyped or conflicting
  /// attribute instead of falling back silently.
  factory ReactViewConfiguration.fromAttributes(Map<String, Object?> attributes) {
    T? read<T extends Object>(String key, {bool required = false}) {
      final Object? value = attributes[key];
      if (value == null) {
        if (required) {
          throw ReactConfigurationException('Missing required attribute "$key"');
        }
        return null;
      }
      if (value is! T) {
        throw ReactConfigurationException('Attribute "$key" must be a $T, got ${value.runtimeType}');
      }
      return value;
    }

    E parseEnum<E extends Enum>(String key, List<E> values, String Function(E) nameOf, E fallback) {
      final String? raw = read<String>(key);
      if (raw == null) {
        return fallback;
      }
      return values.firstWhere(
        (E v) => nameOf(v) == raw,
        orElse: () => throw ReactConfigurationException(
          'Attribute "$key" has unknown value "$raw"; expected one of '
          '${values.map(nameOf).join(', ')}',
        ),
      );
    }

    /// Reads [key] or its [alias]; setting both is ambiguous and rejected.
    String? readAliased(String key, String alias, {bool required = false}) {
      final String? primary = read<String>(key);
      final String? secondary = read<String>(alias);
      if (primary != null && secondary != null) {
        throw ReactConfigurationException('Set either "$key" or "$alias", not both');
      }
      final String? value = primary ?? secondary;
      if (value == null && required) {
        throw ReactConfigurationException('Missing required attribute "$key" (or "$alias")');
      }
      return value;
    }

    final ReactEngineKind engine;
    if (attributes.containsKey('type')) {
      if (attributes.containsKey('engine')) {
        throw const ReactConfigurationException('Set either "engine" or "type", not both');
      }
      read<String>('type', required: true);
      engine = parseEnum<ReactEmbedType>(
        'type',
        ReactEmbedType.values,
        (ReactEmbedType t) => t.name,
        ReactEmbedType.web,
      ).engine;
    } else {
      read<String>('engine', required: true);
      engine = parseEnum<ReactEngineKind>(
        'engine',
        ReactEngineKind.values,
        (ReactEngineKind e) => e.wireName,
        ReactEngineKind.reactNative,
      );
    }
    final int? timeoutMs = read<int>('requestTimeoutMs');
    final Map<String, Object?>? props = read<Map<String, Object?>>('initialProps');

    final ReactViewConfiguration configuration = ReactViewConfiguration(
      engine: ReactEngineConfig(
        engine: engine,
        bundle: readAliased('bundle', 'bundleName', required: true)!,
        bundleSha256: read<String>('bundleSha256'),
        enableDebugging: read<bool>('enableDebugging') ?? false,
        requestTimeout: timeoutMs == null ? const Duration(seconds: 10) : Duration(milliseconds: timeoutMs),
      ),
      moduleName: readAliased('moduleName', 'componentName', required: true)!,
      initialProps: props ?? const <String, Object?>{},
      cacheKey: read<String>('cacheKey'),
      androidComposition: parseEnum<AndroidCompositionMode>(
        'androidComposition',
        AndroidCompositionMode.values,
        (AndroidCompositionMode m) => m.name,
        AndroidCompositionMode.textureLayer,
      ),
    );
    configuration.engine.validate();
    JsonSafety.validate(configuration.initialProps, path: r'$.initialProps');
    return configuration;
  }

  /// Runtime to boot when the view owns its runtime.
  final ReactEngineConfig engine;

  /// Framework type of the embedded app, derived from [engine].
  ReactEmbedType get type => engine.engine.embedType;

  /// React root component name (RN `AppRegistry` key) or SPA route.
  final String moduleName;

  /// Props of the React root. Changing them re-renders without remounting.
  final JsonMap initialProps;

  /// Retains the native surface across unmounts under this key.
  final String? cacheKey;

  /// Android composition strategy.
  final AndroidCompositionMode androidComposition;

  /// How the platform view participates in hit testing.
  final PlatformViewHitTestBehavior hitTestBehavior;

  /// Whether moving from [other] to this configuration needs a new native
  /// surface, as opposed to a props update.
  bool requiresNewSurface(ReactViewConfiguration other) =>
      engine != other.engine ||
      moduleName != other.moduleName ||
      cacheKey != other.cacheKey ||
      androidComposition != other.androidComposition ||
      hitTestBehavior != other.hitTestBehavior;

  @override
  bool operator ==(Object other) =>
      other is ReactViewConfiguration &&
      !requiresNewSurface(other) &&
      _deepEquality.equals(initialProps, other.initialProps);

  @override
  int get hashCode =>
      Object.hash(engine, moduleName, cacheKey, androidComposition, hitTestBehavior, _deepEquality.hash(initialProps));
}

/// Builds the widget shown when a [ReactView] fails. Call [retry] to tear the
/// view down and boot it again.
typedef ReactViewErrorBuilder = Widget Function(BuildContext context, ReactEmbedException error, VoidCallback retry);

/// Receives errors raised by a [ReactView].
typedef ReactViewErrorCallback = void Function(ReactEmbedException error, StackTrace stackTrace);

/// Embeds a React micro-frontend as a platform view.
///
/// One widget serves both framework types, selected by
/// [ReactViewConfiguration.type]:
///
/// | [ReactEmbedType] | Native surface | Platform view type |
/// | --- | --- | --- |
/// | `web` | WebView / WKWebView | `dev.flutter_react_embed/view/web` |
/// | `native` | React Native `ReactSurface` / root view | `dev.flutter_react_embed/view/react_native` |
///
/// ```dart
/// ReactView(configuration: ReactViewConfiguration.web(assetPath: 'assets/react_app/'));
/// ReactView(
///   configuration: ReactViewConfiguration.native(
///     bundleName: 'assets/rn/index.android.bundle',
///     iosBundleName: 'assets/rn/main.jsbundle',
///     componentName: 'Checkout',
///   ),
/// );
/// ```
///
/// The view resolves the execution environment, obtains a runtime (a shared
/// [runtime], a retained surface from [surfaceCache], or a runtime it boots
/// and owns), then spawns the platform view for that environment:
///
/// | Environment | Platform view |
/// | --- | --- |
/// | Android | `PlatformViewLink` + `AndroidViewSurface` |
/// | iOS | `UiKitView` |
/// | Web | `HtmlElementView` |
///
/// ### Error boundary
///
/// Boot failures, invalid props, platform-view creation failures and fatal
/// JavaScript errors switch the view into an error state rendered by
/// [errorBuilder]. They are reported to [onError] or, when it is null, to
/// [FlutterError.reportError]. Non-fatal JS errors are reported only.
///
/// ### Ownership
///
/// A runtime the view boots itself is disposed with the view, unless
/// [ReactViewConfiguration.cacheKey] is set, in which case it lives in
/// [surfaceCache] until evicted. A [runtime] passed in is never disposed by
/// the view.
class ReactView extends StatefulWidget {
  /// Creates a React view.
  const ReactView({
    super.key,
    required this.configuration,
    this.runtime,
    this.surfaceCache,
    this.gestureRecognizers = const <Factory<OneSequenceGestureRecognizer>>{},
    this.onViewCreated,
    this.onError,
    this.placeholderBuilder,
    this.errorBuilder,
  });

  /// What to render and how.
  final ReactViewConfiguration configuration;

  /// A runtime shared with other views. When null the view boots its own
  /// from [ReactViewConfiguration.engine].
  final ReactRuntimeHandle? runtime;

  /// Cache used when [ReactViewConfiguration.cacheKey] is set. Defaults to
  /// [ReactSurfaceCache.shared].
  final ReactSurfaceCache? surfaceCache;

  /// Gestures the platform view claims from Flutter's gesture arena.
  ///
  /// Pass an `EagerGestureRecognizer` factory when React owns scrolling.
  final Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers;

  /// Called once per mounted surface with a controller for it.
  final ValueChanged<ReactViewController>? onViewCreated;

  /// Receives every error the view raises.
  final ReactViewErrorCallback? onError;

  /// Shown while the runtime boots. Defaults to an empty box.
  final WidgetBuilder? placeholderBuilder;

  /// Shown when the view fails. Defaults to [ErrorWidget] in debug builds and
  /// an empty box in release builds.
  final ReactViewErrorBuilder? errorBuilder;

  @override
  State<ReactView> createState() => _ReactViewState();
}

sealed class _Phase {
  const _Phase();
}

final class _Booting extends _Phase {
  const _Booting();
}

final class _Ready extends _Phase {
  const _Ready({
    required this.runtime,
    required this.environment,
    required this.creationParams,
    required this.propsAtCreation,
    required this.reattached,
  });

  final ReactRuntimeHandle runtime;
  final ReactExecutionEnvironment environment;
  final Map<String, Object?> creationParams;
  final JsonMap propsAtCreation;
  final bool reattached;
}

final class _Failed extends _Phase {
  const _Failed(this.error);

  final ReactEmbedException error;
}

class _ReactViewState extends State<ReactView> {
  _Phase _phase = const _Booting();

  /// Bumped on every (re)boot and on dispose; async work from an older
  /// generation discards its result.
  int _generation = 0;

  ReactRuntimeHandle? _runtime;
  bool _ownsRuntime = false;
  String? _claimedCacheKey;
  ReactViewController? _controller;
  final List<StreamSubscription<Object?>> _subscriptions = <StreamSubscription<Object?>>[];

  FlutterReactEmbedPlatform get _platform => FlutterReactEmbedPlatform.instance;

  ReactSurfaceCache get _cache => widget.surfaceCache ?? ReactSurfaceCache.shared;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  @override
  void didUpdateWidget(ReactView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool remount =
        widget.configuration.requiresNewSurface(oldWidget.configuration) ||
        widget.runtime != oldWidget.runtime ||
        widget.surfaceCache != oldWidget.surfaceCache;
    if (remount) {
      _restart();
      return;
    }
    if (!_deepEquality.equals(widget.configuration.initialProps, oldWidget.configuration.initialProps)) {
      _pushProps(widget.configuration.initialProps);
    }
  }

  @override
  void dispose() {
    _generation++;
    _releaseResources();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _boot() async {
    final int generation = ++_generation;
    final ReactViewConfiguration config = widget.configuration;
    final ReactExecutionEnvironment environment = ReactExecutionEnvironment.resolve();

    try {
      if (!environment.supports(config.engine.engine)) {
        throw ReactConfigurationException(
          'Engine ${config.engine.engine.wireName} is not supported on ${environment.name}',
        );
      }
      final ReactRuntimeHandle? shared = widget.runtime;
      if (shared != null && shared.engine != config.engine.engine) {
        throw ReactConfigurationException(
          'Shared runtime is ${shared.engine.wireName} but the configuration '
          'requires ${config.engine.engine.wireName}',
        );
      }

      // 1. Obtain a runtime: retained surface, shared runtime, or a new one.
      final String? cacheKey = config.cacheKey;
      final ReactSurfaceLease? lease = cacheKey == null ? null : _cache.acquire(cacheKey);
      if (cacheKey != null && lease != null) {
        _claimedCacheKey = cacheKey;
      }
      final ReactRuntimeHandle runtime;
      final bool owns;
      if (lease != null) {
        runtime = lease.runtime;
        owns = lease.ownsRuntime;
      } else if (shared != null) {
        runtime = shared;
        owns = false;
      } else {
        runtime = await _platform.initializeEngine(config.engine);
        owns = true;
        // 2. The widget may have been disposed or reconfigured while the
        // engine booted. Nothing recorded this runtime yet, so release it here.
        if (!mounted || generation != _generation) {
          unawaited(_platform.disposeEngine(runtime).catchError((Object _) {}));
          return;
        }
      }
      _runtime = runtime;
      _ownsRuntime = owns;

      if (cacheKey != null && lease == null) {
        _cache.attach(cacheKey, runtime, ownsRuntime: owns);
        _claimedCacheKey = cacheKey;
      }

      // 3. Encode creation params now so build() can never throw on them.
      final Map<String, Object?> creationParams = ReactSurfaceCreationParams(
        runtime: runtime,
        moduleName: config.moduleName,
        initialProps: config.initialProps,
        cacheKey: cacheKey,
      ).toCreationParams();

      _watchRuntime(runtime, generation);

      setState(() {
        _phase = _Ready(
          runtime: runtime,
          environment: environment,
          creationParams: creationParams,
          propsAtCreation: config.initialProps,
          reattached: lease != null,
        );
      });
    } on ReactEmbedException catch (error, stackTrace) {
      _fail(error, stackTrace, generation);
    } catch (error, stackTrace) {
      _fail(
        ReactEngineInitializationException(
          'Unexpected failure while booting ReactView: $error',
          code: 'UNEXPECTED',
          cause: error,
        ),
        stackTrace,
        generation,
      );
    }
  }

  void _restart() {
    _generation++;
    _releaseResources();
    setState(() => _phase = const _Booting());
    unawaited(_boot());
  }

  void _watchRuntime(ReactRuntimeHandle runtime, int generation) {
    _subscriptions
      ..add(
        _platform.runtimeErrors(runtime).listen((ReactRuntimeError error) {
          final ReactJsRuntimeException exception = error.toException();
          if (error.isFatal) {
            _fail(exception, StackTrace.current, generation);
          } else {
            _report(exception, StackTrace.current);
          }
        }),
      )
      ..add(
        _platform.runtimeStates(runtime).listen((ReactRuntimeState state) {
          if (state == ReactRuntimeState.crashed || state == ReactRuntimeState.disposed) {
            _fail(
              ReactJsRuntimeException('React runtime ${runtime.id} is ${state.name}', isFatal: true),
              StackTrace.current,
              generation,
            );
          }
        }),
      );
  }

  void _handlePlatformViewCreated(int viewId, int generation) {
    final _Phase phase = _phase;
    if (!mounted || generation != _generation || phase is! _Ready) {
      return;
    }
    _controller?.dispose();
    final ReactViewController controller = ReactViewController.internal(
      runtime: phase.runtime,
      viewId: viewId,
      platform: _platform,
    );
    _controller = controller;

    // A retained surface still shows its previous props, and props may have
    // changed between creation-param encoding and view creation.
    final JsonMap current = widget.configuration.initialProps;
    if (phase.reattached || !_deepEquality.equals(current, phase.propsAtCreation)) {
      _pushProps(current);
    }
    widget.onViewCreated?.call(controller);
  }

  void _pushProps(JsonMap props) {
    final ReactViewController? controller = _controller;
    if (controller == null) {
      return; // Picked up in _handlePlatformViewCreated.
    }
    final int generation = _generation;
    controller.updateProps(props).catchError((Object error, StackTrace stackTrace) {
      if (generation == _generation) {
        _report(_asReactError(error), stackTrace);
      }
    });
  }

  void _releaseResources() {
    for (final StreamSubscription<Object?> subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _controller?.dispose();
    _controller = null;

    final ReactRuntimeHandle? runtime = _runtime;
    final String? cacheKey = _claimedCacheKey;
    _runtime = null;
    _claimedCacheKey = null;

    if (cacheKey != null) {
      // The cache now decides when the surface (and an owned runtime) dies.
      unawaited(_cache.release(cacheKey));
    } else if (runtime != null && _ownsRuntime) {
      unawaited(
        _platform.disposeEngine(runtime).catchError((Object error, StackTrace stackTrace) {
          _report(_asReactError(error), stackTrace);
        }),
      );
    }
    _ownsRuntime = false;
  }

  void _fail(ReactEmbedException error, StackTrace stackTrace, int generation) {
    if (!mounted || generation != _generation || _phase is _Failed) {
      return;
    }
    _report(error, stackTrace);
    setState(() => _phase = _Failed(error));
  }

  void _report(ReactEmbedException error, StackTrace stackTrace) {
    final ReactViewErrorCallback? onError = widget.onError;
    if (onError != null) {
      onError(error, stackTrace);
      return;
    }
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'flutter_react_embed',
        context: ErrorDescription('in ReactView "${widget.configuration.moduleName}"'),
      ),
    );
  }

  static ReactEmbedException _asReactError(Object error) =>
      error is ReactEmbedException ? error : ReactProtocolException('Unexpected error: $error', cause: error);

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return switch (_phase) {
      _Booting() => widget.placeholderBuilder?.call(context) ?? const SizedBox.shrink(),
      _Failed(:final ReactEmbedException error) =>
        widget.errorBuilder?.call(context, error, _restart) ??
            (kDebugMode ? ErrorWidget(error) : const SizedBox.shrink()),
      final _Ready ready => KeyedSubtree(
        // A new generation must produce a new native view.
        key: ValueKey<int>(_generation),
        child: _buildPlatformView(context, ready),
      ),
    };
  }

  Widget _buildPlatformView(BuildContext context, _Ready ready) {
    final String viewType = _platform.viewTypeFor(ready.runtime.engine);
    final int generation = _generation;
    final ReactViewConfiguration config = widget.configuration;
    final TextDirection direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    void onCreated(int id) => _handlePlatformViewCreated(id, generation);

    switch (ready.environment) {
      case ReactExecutionEnvironment.android:
        return PlatformViewLink(
          viewType: viewType,
          surfaceFactory: (BuildContext context, PlatformViewController controller) {
            return AndroidViewSurface(
              controller: controller as AndroidViewController,
              gestureRecognizers: widget.gestureRecognizers,
              hitTestBehavior: config.hitTestBehavior,
            );
          },
          onCreatePlatformView: (PlatformViewCreationParams params) {
            final AndroidViewController controller = switch (config.androidComposition) {
              AndroidCompositionMode.textureLayer => PlatformViewsService.initSurfaceAndroidView(
                id: params.id,
                viewType: viewType,
                layoutDirection: direction,
                creationParams: ready.creationParams,
                creationParamsCodec: const StandardMessageCodec(),
                onFocus: () => params.onFocusChanged(true),
              ),
              AndroidCompositionMode.hybrid => PlatformViewsService.initExpensiveAndroidView(
                id: params.id,
                viewType: viewType,
                layoutDirection: direction,
                creationParams: ready.creationParams,
                creationParamsCodec: const StandardMessageCodec(),
                onFocus: () => params.onFocusChanged(true),
              ),
            };
            controller
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
              ..addOnPlatformViewCreatedListener(onCreated);
            unawaited(
              controller.create().catchError((Object error, StackTrace stackTrace) {
                _fail(
                  ReactEngineInitializationException(
                    'Android platform view creation failed: $error',
                    code: 'PLATFORM_VIEW_CREATE_FAILED',
                    cause: error,
                  ),
                  stackTrace,
                  generation,
                );
              }),
            );
            return controller;
          },
        );

      case ReactExecutionEnvironment.ios:
        return UiKitView(
          viewType: viewType,
          layoutDirection: direction,
          creationParams: ready.creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          gestureRecognizers: widget.gestureRecognizers,
          hitTestBehavior: config.hitTestBehavior,
          onPlatformViewCreated: onCreated,
        );

      case ReactExecutionEnvironment.web:
        // The web implementation registers `viewType` with
        // `ui_web.platformViewRegistry` and builds the iframe from these params.
        return HtmlElementView(
          viewType: viewType,
          creationParams: ready.creationParams,
          hitTestBehavior: config.hitTestBehavior,
          onPlatformViewCreated: onCreated,
        );

      case ReactExecutionEnvironment.unsupported:
        // Unreachable: _boot() rejects unsupported environments.
        throw StateError('ReactView cannot render on ${defaultTargetPlatform.name}');
    }
  }
}
