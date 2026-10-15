import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_react_embed/flutter_react_embed.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeReactPlatform extends FlutterReactEmbedPlatform {
  final List<String> calls = <String>[];
  final List<(int, JsonMap)> propUpdates = <(int, JsonMap)>[];
  final StreamController<ReactRuntimeError> errors = StreamController<ReactRuntimeError>.broadcast();
  final StreamController<ReactRuntimeState> states = StreamController<ReactRuntimeState>.broadcast();
  Completer<ReactRuntimeHandle>? pendingBoot;
  Object? bootError;
  int _nextId = 0;

  @override
  Future<ReactRuntimeHandle> initializeEngine(ReactEngineConfig config) {
    calls.add('initializeEngine');
    final Object? error = bootError;
    if (error != null) {
      return Future<ReactRuntimeHandle>.error(error);
    }
    final ReactRuntimeHandle handle = ReactRuntimeHandle(id: 'rt-${_nextId++}', engine: config.engine);
    final Completer<ReactRuntimeHandle>? gate = pendingBoot;
    if (gate != null) {
      return gate.future.then((_) => handle);
    }
    return Future<ReactRuntimeHandle>.value(handle);
  }

  @override
  Future<void> disposeEngine(ReactRuntimeHandle runtime) async => calls.add('disposeEngine:${runtime.id}');

  @override
  Future<void> updateProps(int viewId, JsonMap props) async => propUpdates.add((viewId, props));

  @override
  Future<void> evictCachedSurface(String cacheKey) async => calls.add('evict:$cacheKey');

  Future<void> close() async {
    await errors.close();
    await states.close();
  }

  @override
  Stream<ReactRuntimeError> runtimeErrors(ReactRuntimeHandle runtime) => errors.stream;

  @override
  Stream<ReactRuntimeState> runtimeStates(ReactRuntimeHandle runtime) => states.stream;
}

ReactViewConfiguration _config({JsonMap props = const <String, Object?>{}, String? cacheKey}) => ReactViewConfiguration(
  engine: const ReactEngineConfig(engine: ReactEngineKind.reactNative, bundle: 'assets/checkout.hbc'),
  moduleName: 'Checkout',
  initialProps: props,
  cacheKey: cacheKey,
);

void main() {
  late FakeReactPlatform platform;
  late List<MethodCall> platformViewCalls;
  late List<ReactEmbedException> reported;

  Widget host(Widget child) => Directionality(textDirection: TextDirection.ltr, child: child);

  ReactView view(ReactViewConfiguration configuration, {ReactSurfaceCache? cache, Key? key}) => ReactView(
    key: key,
    configuration: configuration,
    surfaceCache: cache,
    onError: (ReactEmbedException e, StackTrace _) => reported.add(e),
    errorBuilder: (BuildContext _, ReactEmbedException e, VoidCallback retry) =>
        GestureDetector(onTap: retry, child: Text('error: ${e.runtimeType}')),
  );

  setUp(() {
    platform = FakeReactPlatform();
    FlutterReactEmbedPlatform.instance = platform;
    platformViewCalls = <MethodCall>[];
    reported = <ReactEmbedException>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (MethodCall call) async {
        platformViewCalls.add(call);
        return null;
      },
    );
  });

  tearDown(() async {
    await platform.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      null,
    );
  });

  testWidgets('boots a runtime, spawns a UiKitView and disposes the runtime with the view', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(view(_config(props: <String, Object?>{'total': 5}))));
    await tester.pumpAndSettle();

    final UiKitView uiKitView = tester.widget<UiKitView>(find.byType(UiKitView));
    expect(uiKitView.viewType, 'dev.flutter_react_embed/view/react_native');
    final Map<Object?, Object?> params = uiKitView.creationParams! as Map<Object?, Object?>;
    expect(params['runtimeId'], 'rt-0');
    expect(params['moduleName'], 'Checkout');
    expect(params['initialPropsJson'], '{"total":5}');
    expect(platformViewCalls.map((MethodCall c) => c.method), contains('create'));

    await tester.pumpWidget(host(const SizedBox()));
    await tester.pumpAndSettle();
    expect(platform.calls, <String>['initializeEngine', 'disposeEngine:rt-0']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('spawns a PlatformViewLink on Android for both composition modes', (WidgetTester tester) async {
    for (final AndroidCompositionMode mode in AndroidCompositionMode.values) {
      platformViewCalls.clear();
      await tester.pumpWidget(
        host(
          view(
            ReactViewConfiguration(
              engine: const ReactEngineConfig(engine: ReactEngineKind.reactNative, bundle: 'assets/checkout.hbc'),
              moduleName: 'Checkout',
              androidComposition: mode,
            ),
            key: ValueKey<AndroidCompositionMode>(mode),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PlatformViewLink), findsOneWidget, reason: mode.name);
      expect(find.byType(AndroidViewSurface), findsOneWidget, reason: mode.name);
      final Map<Object?, Object?> create =
          platformViewCalls.firstWhere((MethodCall c) => c.method == 'create').arguments as Map<Object?, Object?>;
      expect(create['viewType'], 'dev.flutter_react_embed/view/react_native');
      expect(create['hybrid'], mode == AndroidCompositionMode.hybrid ? isTrue : isNot(isTrue), reason: mode.name);
    }
    expect(reported, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('pushes changed props to the mounted surface', (WidgetTester tester) async {
    await tester.pumpWidget(host(view(_config(props: <String, Object?>{'qty': 1}))));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(view(_config(props: <String, Object?>{'qty': 2}))));
    await tester.pumpAndSettle();

    expect(platform.propUpdates.single.$2, <String, Object?>{'qty': 2});
    expect(platform.calls, <String>['initializeEngine'], reason: 'props alone must not remount');
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('renders the error boundary on boot failure and recovers on retry', (WidgetTester tester) async {
    platform.bootError = const ReactEngineInitializationException('no bundle', code: 'BUNDLE_NOT_FOUND');
    await tester.pumpWidget(host(view(_config())));
    await tester.pumpAndSettle();
    expect(find.text('error: ReactEngineInitializationException'), findsOneWidget);
    expect(reported.single, isA<ReactEngineInitializationException>());

    platform.bootError = null;
    await tester.tap(find.byType(GestureDetector));
    await tester.pumpAndSettle();
    expect(find.byType(UiKitView), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a fatal JS error switches to the error boundary', (WidgetTester tester) async {
    await tester.pumpWidget(host(view(_config())));
    await tester.pumpAndSettle();

    platform.errors.add(
      const ReactRuntimeError(
        runtime: ReactRuntimeHandle(id: 'rt-0', engine: ReactEngineKind.reactNative),
        message: 'Invariant Violation',
        isFatal: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('error: ReactJsRuntimeException'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('disposing while the engine boots releases the late runtime', (WidgetTester tester) async {
    platform.pendingBoot = Completer<ReactRuntimeHandle>();
    await tester.pumpWidget(host(view(_config())));
    await tester.pumpWidget(host(const SizedBox()));

    platform.pendingBoot!.complete(const ReactRuntimeHandle(id: 'ignored', engine: ReactEngineKind.reactNative));
    await tester.pumpAndSettle();
    expect(platform.calls, <String>['initializeEngine', 'disposeEngine:rt-0']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('rejects environments without platform view support', (WidgetTester tester) async {
    await tester.pumpWidget(host(view(_config())));
    await tester.pumpAndSettle();
    expect(find.text('error: ReactConfigurationException'), findsOneWidget);
    expect(platform.calls, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a cacheKey keeps the runtime alive across remounts until evicted', (WidgetTester tester) async {
    final ReactSurfaceCache cache = ReactSurfaceCache(maxRetainedSurfaces: 1, platform: platform);

    await tester.pumpWidget(host(view(_config(cacheKey: 'cart'), cache: cache)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(const SizedBox()));
    await tester.pumpAndSettle();
    expect(platform.calls, <String>['initializeEngine'], reason: 'retained, not disposed');

    await tester.pumpWidget(host(view(_config(cacheKey: 'cart'), cache: cache)));
    await tester.pumpAndSettle();
    expect(platform.calls, <String>['initializeEngine'], reason: 'reattached without booting');
    expect(platform.propUpdates, hasLength(1), reason: 'reattached surface receives current props');

    await tester.pumpWidget(host(const SizedBox()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(view(_config(cacheKey: 'help'), cache: cache)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(const SizedBox()));
    await tester.pumpAndSettle();
    expect(platform.calls, <String>['initializeEngine', 'initializeEngine', 'evict:cart', 'disposeEngine:rt-0']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('selects the platform view type from ReactEmbedType', (WidgetTester tester) async {
    for (final ReactEmbedType type in ReactEmbedType.values) {
      final ReactViewConfiguration configuration = switch (type) {
        ReactEmbedType.web => ReactViewConfiguration.web(assetPath: 'assets/react_app/', route: '#/cart'),
        ReactEmbedType.native => ReactViewConfiguration.native(
          bundleName: 'assets/rn/index.android.bundle',
          iosBundleName: 'assets/rn/main.jsbundle',
          componentName: 'Checkout',
        ),
      };
      await tester.pumpWidget(host(view(configuration, key: ValueKey<ReactEmbedType>(type))));
      await tester.pumpAndSettle();

      final UiKitView uiKitView = tester.widget<UiKitView>(find.byType(UiKitView));
      expect(uiKitView.viewType, 'dev.flutter_react_embed/view/${type.engine.wireName}', reason: type.name);
      final Map<Object?, Object?> params = uiKitView.creationParams! as Map<Object?, Object?>;
      expect(params['engine'], type.engine.wireName, reason: type.name);
    }
    expect(reported, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  group('ReactEmbedType', () {
    test('maps one to one onto ReactEngineKind', () {
      expect(ReactEmbedType.web.engine, ReactEngineKind.web);
      expect(ReactEmbedType.native.engine, ReactEngineKind.reactNative);
      for (final ReactEngineKind engine in ReactEngineKind.values) {
        expect(engine.embedType.engine, engine);
      }
    });

    test('web() builds the same configuration as the explicit constructor', () {
      expect(
        ReactViewConfiguration.web(assetPath: 'assets/react_app/', route: '#/cart', cacheKey: 'cart'),
        const ReactViewConfiguration(
          engine: ReactEngineConfig(engine: ReactEngineKind.web, bundle: 'assets/react_app/'),
          moduleName: '#/cart',
          cacheKey: 'cart',
        ),
      );
    });

    test('native() picks the bundle for the target platform', () {
      ReactViewConfiguration build() => ReactViewConfiguration.native(
        bundleName: 'assets/rn/index.android.bundle',
        iosBundleName: 'assets/rn/main.jsbundle',
        componentName: 'Checkout',
        initialProps: const <String, Object?>{'total': 5},
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final ReactViewConfiguration android = build();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final ReactViewConfiguration ios = build();
      debugDefaultTargetPlatformOverride = null;

      expect(android.type, ReactEmbedType.native);
      expect(android.engine.bundle, 'assets/rn/index.android.bundle');
      expect(ios.engine.bundle, 'assets/rn/main.jsbundle');
      expect(ios.moduleName, 'Checkout');
      expect(ios.initialProps, const <String, Object?>{'total': 5});
    });
  });

  group('ReactViewConfiguration.fromAttributes', () {
    test('accepts the type, bundleName and componentName aliases', () {
      final ReactViewConfiguration config = ReactViewConfiguration.fromAttributes(<String, Object?>{
        'type': 'native',
        'bundleName': 'assets/rn/index.android.bundle',
        'componentName': 'Checkout',
      });
      expect(config.type, ReactEmbedType.native);
      expect(config.engine.engine, ReactEngineKind.reactNative);
      expect(config.engine.bundle, 'assets/rn/index.android.bundle');
      expect(config.moduleName, 'Checkout');
    });

    test('rejects an attribute set together with its alias', () {
      expect(
        () => ReactViewConfiguration.fromAttributes(<String, Object?>{
          'engine': 'web',
          'type': 'web',
          'bundle': 'b',
          'moduleName': 'm',
        }),
        throwsA(isA<ReactConfigurationException>()),
      );
      expect(
        () => ReactViewConfiguration.fromAttributes(<String, Object?>{
          'type': 'native',
          'bundle': 'b',
          'bundleName': 'c',
          'moduleName': 'm',
        }),
        throwsA(isA<ReactConfigurationException>()),
      );
    });

    test('reads a complete manifest', () {
      final ReactViewConfiguration config = ReactViewConfiguration.fromAttributes(<String, Object?>{
        'engine': 'web',
        'bundle': 'assets/help/',
        'moduleName': '/faq',
        'initialProps': <String, Object?>{'locale': 'en'},
        'androidComposition': 'hybrid',
        'requestTimeoutMs': 2500,
      });
      expect(config.engine.engine, ReactEngineKind.web);
      expect(config.engine.requestTimeout, const Duration(milliseconds: 2500));
      expect(config.androidComposition, AndroidCompositionMode.hybrid);
    });

    test('fails loudly on missing or mistyped attributes', () {
      expect(
        () => ReactViewConfiguration.fromAttributes(<String, Object?>{'bundle': 'b', 'moduleName': 'm'}),
        throwsA(isA<ReactConfigurationException>()),
      );
      expect(
        () => ReactViewConfiguration.fromAttributes(<String, Object?>{
          'engine': 'flash',
          'bundle': 'b',
          'moduleName': 'm',
        }),
        throwsA(isA<ReactConfigurationException>()),
      );
      expect(
        () => ReactViewConfiguration.fromAttributes(<String, Object?>{'engine': 'web', 'bundle': 'b', 'moduleName': 7}),
        throwsA(isA<ReactConfigurationException>()),
      );
    });
  });
}
