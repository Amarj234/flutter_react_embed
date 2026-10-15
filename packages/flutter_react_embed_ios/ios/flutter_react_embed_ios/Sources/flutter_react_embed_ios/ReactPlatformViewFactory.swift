import Flutter
import UIKit

/// Creates `ReactPlatformView`s for `dev.flutter_react_embed/view/web`.
final class ReactPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private let registry: RuntimeRegistry
  private weak var events: RuntimeEvents?

  init(registry: RuntimeRegistry, events: RuntimeEvents) {
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
    ReactPlatformView(frame: frame, viewId: viewId, arguments: args, registry: registry, events: events)
  }
}

/// Flutter-side handle for one embedded React surface.
///
/// The view is a plain container; the runtime's `WKWebView` is moved into it
/// on creation. Creation never throws: Flutter cannot surface a factory error
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
  private let registry: RuntimeRegistry
  private weak var runtime: WebRuntime?
  private var cacheKey: String?

  init(
    frame: CGRect, viewId: Int64, arguments: Any?, registry: RuntimeRegistry,
    events: RuntimeEvents?
  ) {
    self.container = UIView(frame: frame)
    self.viewId = viewId
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
    guard params.engine == FREProtocol.engineWeb else {
      return "Engine \(params.engine) is not supported by this view type"
    }
    guard let target = registry.runtime(params.runtimeId) else {
      return "Runtime \(params.runtimeId) does not exist or was disposed"
    }
    if let error = target.attach(viewId: viewId, container: container, params: params) {
      return error
    }
    runtime = target
    registry.bind(viewId: viewId, runtimeId: target.id)
    return nil
  }

  /// Detaches the web view and unbinds the surface.
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
