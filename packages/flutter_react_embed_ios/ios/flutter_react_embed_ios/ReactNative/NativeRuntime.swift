import Foundation
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider
import UIKit

// Compiled only with the `flutter_react_embed_ios/ReactNative` subspec, which
// also defines `FRE_REACT_NATIVE` for the plugin's core sources.

/// Lets the app supply the React Native factory used by the `react_native`
/// engine, for apps that already run React Native or need a custom delegate.
///
/// Call once before the first `ReactView` with a native configuration mounts,
/// typically in `application(_:didFinishLaunchingWithOptions:)`. The factory's
/// own bundle URL is then loaded and the Dart-side bundle name is only checked
/// for existence. The app must keep the factory's delegate alive (the factory
/// holds it weakly).
public enum FlutterReactEmbedReactNativeHost {
  public static func use(_ factory: RCTReactNativeFactory) {
    EmbedQueues.onMain { ReactNativeHostHolder.shared.provide(factory) }
  }
}

/// One `react_native` runtime: a logical session on the process-wide
/// `RCTReactNativeFactory` owned by `ReactNativeHostHolder`.
///
/// React Native runs one JavaScript instance per host, so runtimes share it and
/// are told apart by `runtimeId`, which every surface receives in its initial
/// props under `FREProtocol.rnMetaProp`. Unlike a web document, one runtime can
/// show any number of surfaces at once.
///
/// ### Threading
/// All state is confined to the main thread. Frames from JS arrive on the
/// module's method queue and hop through `EmbedQueues.bridge` (size check)
/// back to main, preserving order.
///
/// ### Lifecycle
/// - `boot` obtains the factory; its React host starts with the first surface.
/// - `attach` creates a root view, or reattaches one retained under a cache key.
/// - `detach` removes the root view; without a cache key its surface is stopped
///   and released.
/// - `dispose` stops every surface and unregisters from `NativeBridgeHub`. The
///   factory stays resident (see `ReactNativeHostHolder`).
///
/// ### JS contract
/// Identical to Android: `NativeModules.FlutterReactEmbed.postMessage(runtimeId,
/// frame)` for JS -> host, `freFrame` events `{runtimeId, frame}` for
/// host -> JS, and the first frame of a runtime as its readiness signal.
final class NativeRuntime: NSObject, EmbedRuntime {
  private enum Phase { case created, ready, disposed }

  /// A root view and what it was created for.
  private struct Mounted {
    let view: UIView
    let moduleName: String
    let cacheKey: String?
  }

  let id: String
  let engine = FREProtocol.engineReactNative
  private let config: RuntimeConfig
  private let bundleURL: URL
  private let queues: EmbedQueues
  private weak var events: RuntimeEvents?

  private var phase = Phase.created
  private var factory: RCTReactNativeFactory?
  private var mounted: [Int64: Mounted] = [:]
  private var retained: [String: Mounted] = [:]
  private var pendingOutbound: [String] = []
  private var jsConnected = false

  init(id: String, config: RuntimeConfig, bundleURL: URL, queues: EmbedQueues, events: RuntimeEvents) {
    self.id = id
    self.config = config
    self.bundleURL = bundleURL
    self.queues = queues
    self.events = events
    super.init()
  }

  // MARK: - Boot

  /// Obtains the shared factory. `completion` runs synchronously; JS
  /// readiness is signalled later by the runtime's first frame.
  func boot(completion: (FREError?) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    precondition(phase == .created, "Runtime \(id) already booted")
    switch ReactNativeHostHolder.shared.obtain(bundleURL: bundleURL) {
    case .failure(let error):
      phase = .disposed
      completion(error)
    case .success(let factory):
      self.factory = factory
      phase = .ready
      NativeBridgeHub.shared.register(self)
      completion(nil)
      events?.runtime(id, didChangeState: FREProtocol.stateReady)
    }
  }

  // MARK: - JS -> Dart (called by NativeBridgeHub on main)

  func receiveFromJs(_ frame: String) {
    let limit = config.maxMessageBytes
    queues.bridge.async { [weak self] in
      let bytes = frame.utf8.count
      DispatchQueue.main.async {
        guard let self, self.phase == .ready else { return }
        if bytes > limit {
          self.events?.runtime(
            self.id, didFail: "Dropped a \(bytes)-byte frame from JS (limit \(limit))", stack: nil,
            fatal: false)
          return
        }
        if !self.jsConnected {
          // First frame = this runtime's JS bridge is listening.
          self.jsConnected = true
          self.flushPendingOutbound()
        }
        self.events?.runtime(self.id, didEmitFrame: frame)
      }
    }
  }

  /// The JS instance went away (reload or teardown): re-handshake on the next one.
  func jsContextLost() {
    jsConnected = false
  }

  // MARK: - Dart -> JS

  func deliverFromDart(_ frame: String, completion: @escaping (FREError?) -> Void) {
    let limit = config.maxMessageBytes
    queues.bridge.async { [weak self] in
      let bytes = frame.utf8.count
      DispatchQueue.main.async {
        guard let self else { return completion(.engineDisposed("Runtime was released")) }
        if bytes > limit { return completion(.payloadTooLarge(bytes, limit: limit)) }
        guard self.phase == .ready else {
          return completion(.engineDisposed("Runtime \(self.id) is not running"))
        }
        completion(self.postToJs(frame))
      }
    }
  }

  @discardableResult
  private func postToJs(_ frame: String) -> FREError? {
    if phase == .ready, jsConnected, NativeBridgeHub.shared.emit(runtimeId: id, frame: frame) {
      return nil
    }
    guard pendingOutbound.count < FREProtocol.maxPendingOutbound else { return .queueFull }
    pendingOutbound.append(frame)
    return nil
  }

  private func flushPendingOutbound() {
    while let frame = pendingOutbound.first {
      guard NativeBridgeHub.shared.emit(runtimeId: id, frame: frame) else { return }
      pendingOutbound.removeFirst()
    }
  }

  // MARK: - Surfaces

  func retains(_ cacheKey: String) -> Bool { retained[cacheKey] != nil }

  func attach(viewId: Int64, container: UIView, params: SurfaceParams) -> String? {
    dispatchPrecondition(condition: .onQueue(.main))
    guard phase == .ready, let factory else { return "Runtime \(id) is not available" }
    guard mounted[viewId] == nil else { return "View \(viewId) already shows a surface of runtime \(id)" }
    let props: [String: Any]
    do {
      props = try FREProtocol.parseObject(params.initialPropsJson)
    } catch {
      return "initialPropsJson is not a JSON object"
    }
    let initialProperties = propsWithMeta(props, viewId: viewId, cacheKey: params.cacheKey)

    let entry: Mounted
    if let cacheKey = params.cacheKey {
      if mounted.values.contains(where: { $0.cacheKey == cacheKey }) {
        return "Surface \"\(cacheKey)\" is already on screen; a cached surface can only be shown once"
      }
      if let reused = retained[cacheKey], reused.moduleName == params.moduleName {
        retained.removeValue(forKey: cacheKey)
        // The retained tree still carries the previous viewId and props.
        (reused.view as? RCTSurfaceHostingProxyRootView)?.appProperties = initialProperties
        entry = reused
      } else {
        if let stale = retained.removeValue(forKey: cacheKey) { release(stale) }
        entry = Mounted(
          view: factory.rootViewFactory.view(
            withModuleName: params.moduleName, initialProperties: initialProperties),
          moduleName: params.moduleName, cacheKey: cacheKey)
      }
    } else {
      entry = Mounted(
        view: factory.rootViewFactory.view(
          withModuleName: params.moduleName, initialProperties: initialProperties),
        moduleName: params.moduleName, cacheKey: nil)
    }

    entry.view.removeFromSuperview()
    entry.view.frame = container.bounds
    entry.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    entry.view.backgroundColor = .clear
    container.addSubview(entry.view)
    mounted[viewId] = entry
    return nil
  }

  func detach(viewId: Int64, cacheKey: String?) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let entry = mounted.removeValue(forKey: viewId) else { return }
    entry.view.removeFromSuperview()
    if let cacheKey, cacheKey == entry.cacheKey, phase == .ready {
      if let stale = retained.updateValue(entry, forKey: cacheKey) { release(stale) }
    } else {
      release(entry)
    }
  }

  func evictCached(_ cacheKey: String) {
    if let entry = retained.removeValue(forKey: cacheKey) { release(entry) }
  }

  func updateProps(viewId: Int64, props: [String: Any]) -> FREError? {
    guard let entry = mounted[viewId] else { return .unknownView(viewId) }
    guard let root = entry.view as? RCTSurfaceHostingProxyRootView else {
      // Unknown root view class: let the JS bridge apply them.
      guard let frame = FREProtocol.notification("$/updateProps", ["viewId": viewId, "props": props])
      else { return .invalidArguments("props are not JSON-serializable") }
      return postToJs(frame)
    }
    root.appProperties = propsWithMeta(props, viewId: viewId, cacheKey: entry.cacheKey)
    return nil
  }

  private func propsWithMeta(_ props: [String: Any], viewId: Int64, cacheKey: String?) -> [String: Any] {
    var merged = props
    merged[FREProtocol.rnMetaProp] = [
      "runtimeId": id,
      "viewId": viewId,
      "contractVersion": config.contractVersion,
      "platform": "ios",
      "cacheKey": cacheKey ?? NSNull(),
    ] as [String: Any]
    return merged
  }

  // MARK: - Teardown

  /// Stops the surface explicitly instead of waiting for the view's dealloc,
  /// so its React tree unmounts now even if UIKit still holds the view.
  private func release(_ entry: Mounted) {
    entry.view.removeFromSuperview()
    (entry.view as? RCTSurfaceHostingView)?.surface.stop()
  }

  func dispose() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard phase != .disposed else { return }
    phase = .disposed
    pendingOutbound.removeAll()
    let entries = Array(mounted.values) + Array(retained.values)
    mounted.removeAll()
    retained.removeAll()
    entries.forEach(release)
    NativeBridgeHub.shared.unregister(self)
    factory = nil
  }
}

/// Plugin-created factory delegate that loads the Flutter asset bundle.
private final class EmbedReactNativeDelegate: RCTDefaultReactNativeFactoryDelegate {
  private let bundle: URL

  init(bundle: URL) {
    self.bundle = bundle
    super.init()
  }

  override func sourceURL(for bridge: RCTBridge) -> URL? { bundleURL() }

  override func bundleURL() -> URL? { bundle }
}

/// Lazily created, process-wide `RCTReactNativeFactory`. Main thread only.
///
/// Uses the factory passed to `FlutterReactEmbedReactNativeHost.use(_:)` when
/// there is one; otherwise builds one over the Flutter asset bundle
/// (`main.jsbundle`). The factory, and with it the React host, stays resident
/// for the life of the process: runtimes come and go, but restarting Hermes
/// and re-evaluating the bundle costs more than keeping them.
final class ReactNativeHostHolder {
  static let shared = ReactNativeHostHolder()

  private var factory: RCTReactNativeFactory?
  /// Strong reference: the factory holds its delegate weakly.
  private var delegate: EmbedReactNativeDelegate?
  private var bundleURL: URL?
  private var ownsFactory = false

  func provide(_ factory: RCTReactNativeFactory) {
    guard self.factory == nil else {
      NSLog("[FlutterReactEmbed] a React Native factory is already in use; ignoring the provided one")
      return
    }
    self.factory = factory
    ownsFactory = false
  }

  func obtain(bundleURL: URL) -> Result<RCTReactNativeFactory, FREError> {
    if let factory {
      if ownsFactory, let current = self.bundleURL, current != bundleURL {
        return .failure(
          .engineInitFailed(
            "React Native is already running \(current.lastPathComponent); one process hosts one React Native bundle"
          ))
      }
      return .success(factory)
    }
    let delegate = EmbedReactNativeDelegate(bundle: bundleURL)
    let created = RCTReactNativeFactory(delegate: delegate)
    delegate.dependencyProvider = RCTAppDependencyProvider()
    self.delegate = delegate
    self.factory = created
    self.bundleURL = bundleURL
    ownsFactory = true
    return .success(created)
  }
}

/// Routes frames between `NativeRuntime`s and the JS instance's
/// `FlutterReactEmbedModule`. Main thread only, except `fromJs`.
final class NativeBridgeHub {
  static let shared = NativeBridgeHub()

  private var runtimes: [String: NativeRuntime] = [:]
  private weak var module: FlutterReactEmbedModule?

  func register(_ runtime: NativeRuntime) { runtimes[runtime.id] = runtime }

  func unregister(_ runtime: NativeRuntime) { runtimes.removeValue(forKey: runtime.id) }

  /// Sends `frame` to JS. Returns false when no JS listener is attached.
  func emit(runtimeId: String, frame: String) -> Bool {
    guard let module, module.isObserving else { return false }
    module.sendEvent(withName: FREProtocol.rnFrameEvent, body: ["runtimeId": runtimeId, "frame": frame])
    return true
  }

  /// Called on the module's method queue.
  func fromJs(runtimeId: String, frame: String) {
    DispatchQueue.main.async { self.runtimes[runtimeId]?.receiveFromJs(frame) }
  }

  func moduleStartedObserving(_ started: FlutterReactEmbedModule) {
    EmbedQueues.onMain { self.module = started }
  }

  func moduleInvalidated(_ invalidated: FlutterReactEmbedModule) {
    EmbedQueues.onMain {
      if self.module === invalidated { self.module = nil }
      self.runtimes.values.forEach { $0.jsContextLost() }
    }
  }
}

/// `NativeModules.FlutterReactEmbed`: the JS side of the frame transport.
/// Exported by `FlutterReactEmbedModule.m` and served through React Native's
/// legacy-module interop layer, so it needs no codegen spec in the app.
@objc(FlutterReactEmbed)
final class FlutterReactEmbedModule: RCTEventEmitter {
  private let observingLock = NSLock()
  private var observing = false

  /// Whether JS has a `freFrame` listener. Read on main, written on the method queue.
  var isObserving: Bool {
    observingLock.lock()
    defer { observingLock.unlock() }
    return observing
  }

  @objc static func requiresMainQueueSetup() -> Bool { false }

  override func supportedEvents() -> [String]! { [FREProtocol.rnFrameEvent] }

  override func startObserving() {
    setObserving(true)
    NativeBridgeHub.shared.moduleStartedObserving(self)
  }

  override func stopObserving() {
    setObserving(false)
  }

  override func invalidate() {
    setObserving(false)
    NativeBridgeHub.shared.moduleInvalidated(self)
    super.invalidate()
  }

  @objc(postMessage:frame:)
  func postMessage(_ runtimeId: String, frame: String) {
    NativeBridgeHub.shared.fromJs(runtimeId: runtimeId, frame: frame)
  }

  private func setObserving(_ value: Bool) {
    observingLock.lock()
    observing = value
    observingLock.unlock()
  }
}
