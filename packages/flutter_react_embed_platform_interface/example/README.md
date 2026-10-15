# Example

Apps use this package through [`flutter_react_embed`](https://pub.dev/packages/flutter_react_embed). To talk to a runtime directly through the platform interface:

```dart
import 'package:flutter_react_embed_platform_interface/flutter_react_embed_platform_interface.dart';

Future<void> main() async {
  final FlutterReactEmbedPlatform platform = FlutterReactEmbedPlatform.instance;
  final ReactRuntimeHandle runtime = await platform.initializeEngine(
    const ReactEngineConfig(engine: ReactEngineKind.web, bundle: 'assets/react_app/'),
  );
  final Object? cart = await platform.invoke(runtime, 'getCart');
  print(cart);
  await platform.disposeEngine(runtime);
}
```
