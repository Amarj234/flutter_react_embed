/// Embed React Native surfaces and production React SPAs inside Flutter.
///
/// Start with [ReactView]; share runtimes across views with
/// [FlutterReactEmbedPlatform.initializeEngine].
library;

export 'package:flutter_react_embed_platform_interface/flutter_react_embed_platform_interface.dart'
    show
        FlutterReactEmbedPlatform,
        JsonMap,
        JsonRpcErrorCode,
        ReactBridgeEvent,
        ReactConfigurationException,
        ReactEmbedException,
        ReactEngineConfig,
        ReactEngineInitializationException,
        ReactEngineKind,
        ReactEngineUnavailableException,
        ReactHandlerDisposer,
        ReactJsRuntimeException,
        ReactProtocolException,
        ReactRpcException,
        ReactRpcHandler,
        ReactRpcTimeoutException,
        ReactRuntimeDisposedException,
        ReactRuntimeError,
        ReactRuntimeHandle,
        ReactRuntimeState,
        ReactSerializationException;

export 'src/presentation/react_surface_cache.dart';
export 'src/presentation/react_view.dart';
export 'src/presentation/react_view_controller.dart';
