# Changelog

## 1.0.0

Initial release.

- `FlutterReactEmbedPlatform`: federated contract for engine lifecycle, props, JSON-RPC messaging, events, runtime state and errors, and the surface cache.
- `MethodChannelFlutterReactEmbed`: default implementation over two MethodChannels, with buffering of frames and events that arrive before Dart subscribes.
- `JsonRpcCodec` and `JsonRpcEndpoint`: transport-agnostic JSON-RPC 2.0 with strict validation, batches, timeouts and cancellation.
- `JsonSafety`: validation of bridge-safe JSON, reporting the path of any invalid value.
- Sealed `ReactEmbedException` hierarchy.
