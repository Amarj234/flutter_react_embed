# flutter_react_embed_platform_interface

A common platform interface for the [`flutter_react_embed`](https://pub.dev/packages/flutter_react_embed) plugin.

This interface allows platform-specific implementations of `flutter_react_embed`, and the plugin itself, to ensure they support the same interface. It also contains the JSON-RPC 2.0 protocol layer (`JsonRpcCodec`, `JsonRpcEndpoint`, `JsonSafety`) and the default `MethodChannelFlutterReactEmbed` implementation.

## Usage

To implement a new platform-specific implementation of `flutter_react_embed`, extend `FlutterReactEmbedPlatform` with an implementation of the platform behavior, and set it as the default during registration:

```dart
FlutterReactEmbedPlatform.instance = MyPlatformFlutterReactEmbed();
```

## Note on breaking changes

Strongly prefer non-breaking changes, such as adding a method to the interface, over breaking changes for this package. See [the Flutter guidance on platform interface changes](https://flutter.dev/go/platform-interface-breaking-changes) for details.
