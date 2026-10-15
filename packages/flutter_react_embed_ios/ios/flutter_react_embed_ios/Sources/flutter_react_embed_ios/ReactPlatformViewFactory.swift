import Flutter
import UIKit

/// Creates `ReactPlatformView`s. One instance is registered per view type:
/// `dev.flutter_react_embed/view/web` and
/// `dev.flutter_react_embed/view/react_native`.
final class ReactPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private let engine: String
  private let registry: RuntimeRegistry
  private weak var events: RuntimeEvents?

  init(engine: String, registry: RuntimeRegistry, events: RuntimeEvents) {
    self.engine = engine
    self.registry = registry
    self.events = events
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    ReactPlatformView(
      frame: frame, viewId: viewId, arguments: args, engine: engine, registry: registry, events: events)
  }
}

/// Flutter-side handle for one embedded React surface.
///
/// The view is a plain container that switches on the engine:
///
/// - `web`: the runtime's `WKWebView` is moved into it on creation.
/// - `react_native`: an `RCTSurfaceHostingProxyRootView` is created (or a
///   retained one reattached) on creation.
///
/// Creation never throws: Flutter cannot surface a factory error
/// to Dart, so failures leave an empty container and are reported through
/// `onRuntimeError` (non-fatal).
///
/// iOS has no explicit dispose callback for platform views: Flutter releases
/// the `FlutterPlatformView` when the Dart side disposes it. Teardown therefore
/// runs from `deinit`, and the view keeps no strong reference that could keep
/// itself alive (the registry stores only ids, the runtime only the view id).
final class ReactPlatformView: NSObject, FlutterPlatformView {
  private let container: UIView
  private let viewId: Int64
  private let engine: String
  private let registry: RuntimeRegistry
  private weak var runtime: EmbedRuntime?
  private var cacheKey: String?

  init(
    frame: CGRect, viewId: Int64, arguments: Any?, engine: String, registry: RuntimeRegistry,
    events: RuntimeEvents?
  ) {
    self.container = UIView(frame: frame)
    self.viewId = viewId
    self.engine = engine
    self.registry = registry
    super.init()
    container.clipsToBounds = true
    container.backgroundColor = .clear

    do {
      let params = try SurfaceParams(arguments: arguments)
      cacheKey = params.cacheKey
      if let error = mount(params) {
        NSLog("[FlutterReactEmbed] platform view \(viewId): \(error)")
        events?.runtime(params.runtimeId, didFail: error, stack: nil, fatal: false)
      }
    } catch {
      NSLog("[FlutterReactEmbed] platform view \(viewId): invalid creation params")
    }
  }

  func view() -> UIView { container }

  private func mount(_ params: SurfaceParams) -> String? {
    guard params.engine == engine else {
      return "Engine \(params.engine) is not supported by the \(engine) view type"
    }
    guard let target = registry.runtime(params.runtimeId) else {
      return "Runtime \(params.runtimeId) does not exist or was disposed"
    }
    guard target.engine == params.engine else {
      return "Runtime \(params.runtimeId) runs \(target.engine), not \(params.engine)"
    }
    if let error = target.attach(viewId: viewId, container: container, params: params) {
      return error
    }
    runtime = target
    registry.bind(viewId: viewId, runtimeId: target.id)
    return nil
  }

  /// Detaches the surface and unbinds it.
  ///
  /// Flutter disposes platform views on the platform (main) thread. If the
  /// last reference is ever dropped elsewhere, the work is re-dispatched to
  /// main with only the values it needs, never `self`.
  deinit {
    let (viewId, cacheKey, registry, runtime) = (self.viewId, self.cacheKey, self.registry, self.runtime)
    let teardown = {
      runtime?.detach(viewId: viewId, cacheKey: cacheKey)
      registry.unbind(viewId: viewId)
    }
    if Thread.isMainThread { teardown() } else { DispatchQueue.main.async(execute: teardown) }
  }
}
