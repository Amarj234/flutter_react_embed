import Flutter
import UIKit

/// iOS host for flutter_react_embed.
///
/// Serves the protocol of `MethodChannelFlutterReactEmbed`:
///
/// | Channel | Direction | Methods |
/// | --- | --- | --- |
/// | control | Dart -> native | initializeEngine, disposeEngine, updateProps, evictCachedSurface |
/// | messages | Dart -> native | deliver |
/// | messages | native -> Dart | onFrame, onRuntimeState, onRuntimeError |
///
/// Only the `web` engine is implemented. `react_native` is rejected with
/// `UNSUPPORTED_ENGINE`; it needs a React Native host integration (RCTHost,
/// Hermes, CocoaPods codegen) in the consuming app, which a plugin cannot
/// provide.
///
/// One instance exists per FlutterEngine. Channel handlers run on the main
/// thread; background work goes through `EmbedQueues`.
public final class FlutterReactEmbedPlugin: NSObject, FlutterPlugin {
  private let control: FlutterMethodChannel
  private let messages: FlutterMethodChannel
  private weak var registrar: FlutterPluginRegistrar?
  private let queues = EmbedQueues()
  private let registry = RuntimeRegistry()
  private var detached = false

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    control = FlutterMethodChannel(name: FREProtocol.controlChannel, binaryMessenger: registrar.messenger())
    messages = FlutterMethodChannel(name: FREProtocol.messageChannel, binaryMessenger: registrar.messenger())
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FlutterReactEmbedPlugin(registrar: registrar)
    registrar.addMethodCallDelegate(instance, channel: instance.control)
    instance.messages.setMethodCallHandler { [weak instance] call, result in
      guard let instance else {
        return result(FlutterError(code: "ENGINE_DISPOSED", message: "Plugin released", details: nil))
      }
      instance.handleMessage(call, result: result)
    }
    registrar.register(
      ReactPlatformViewFactory(registry: instance.registry, events: instance),
      withId: FREProtocol.viewTypeWeb)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    detached = true
    control.setMethodCallHandler(nil)
    messages.setMethodCallHandler(nil)
    registry.disposeAll()
  }

  // MARK: - Dart -> native

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "initializeEngine":
      initializeEngine(arguments: call.arguments, reply: SingleReply(result))
    case "disposeEngine":
      guard let runtimeId = args?["runtimeId"] as? String else {
        return result(FREError.invalidArguments("runtimeId is required").flutterError)
      }
      registry.remove(runtimeId)?.dispose()
      result(nil)
    case "updateProps":
      updateProps(arguments: args, reply: SingleReply(result))
    case "evictCachedSurface":
      guard let cacheKey = args?["cacheKey"] as? String else {
        return result(FREError.invalidArguments("cacheKey is required").flutterError)
      }
      registry.runtimeRetaining(cacheKey)?.evictCached(cacheKey)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleMessage(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "deliver" else { return result(FlutterMethodNotImplemented) }
    let args = call.arguments as? [String: Any]
    guard let runtimeId = args?["runtimeId"] as? String, let frame = args?["frame"] as? String else {
      return result(FREError.invalidArguments("deliver requires runtimeId and frame").flutterError)
    }
    guard let runtime = registry.runtime(runtimeId) else {
      return result(FREError.unknownRuntime(runtimeId).flutterError)
    }
    let reply = SingleReply(result)
    runtime.deliverFromDart(frame) { error in
      if let error { reply.error(error) } else { reply.success(nil) }
    }
  }

  private func initializeEngine(arguments: Any?, reply: SingleReply) {
    let config: RuntimeConfig
    do {
      config = try RuntimeConfig(arguments: arguments)
    } catch let error as FREError {
      return reply.error(error)
    } catch {
      return reply.error(.invalidArguments("Invalid config"))
    }
    switch config.engine {
    case FREProtocol.engineWeb:
      break
    case FREProtocol.engineReactNative:
      return reply.error(
        .unsupportedEngine(
          "The react_native engine requires a React Native host integration in the app; "
            + "this build of flutter_react_embed_ios provides the web engine only"))
    default:
      return reply.error(.unsupportedEngine("Unknown engine \(config.engine)"))
    }

    guard let registrar else { return reply.error(.engineDisposed("Plugin is detached")) }
    let key = registrar.lookupKey(forAsset: config.bundle.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    guard let path = Bundle.main.path(forResource: key, ofType: nil) else {
      return reply.error(.bundleNotFound(config.bundle))
    }
    let root = URL(fileURLWithPath: path, isDirectory: true)

    // Asset reads and hashing happen off the main thread.
    queues.io.async { [weak self] in
      let check = BundleVerifier.verify(root: root, expectedSha256: config.bundleSha256)
      DispatchQueue.main.async {
        guard let self, !self.detached else {
          return reply.error(.engineDisposed("Plugin detached during boot"))
        }
        switch check {
        case .failure(let error): reply.error(error)
        case .success: self.boot(config: config, root: root, reply: reply)
        }
      }
    }
  }

  private func boot(config: RuntimeConfig, root: URL, reply: SingleReply) {
    let runtime = WebRuntime(
      id: UUID().uuidString, config: config, bundleRoot: root, queues: queues, events: self)
    registry.add(runtime)
    runtime.boot { [weak self, weak runtime] error in
      guard let runtime else { return reply.error(.engineDisposed("Runtime was released during boot")) }
      if let error {
        self?.registry.remove(runtime.id)
        runtime.dispose()
        reply.error(error)
      } else {
        reply.success(["runtimeId": runtime.id])
      }
    }
  }

  private func updateProps(arguments: [String: Any]?, reply: SingleReply) {
    guard let viewId = (arguments?["viewId"] as? NSNumber)?.int64Value,
      let propsJson = arguments?["propsJson"] as? String
    else {
      return reply.error(.invalidArguments("updateProps requires viewId and propsJson"))
    }
    // Props can be large; parse them on the bridge queue.
    queues.bridge.async { [weak self] in
      let parsed = Result { try FREProtocol.parseObject(propsJson) }
      DispatchQueue.main.async {
        guard let self else { return reply.error(.engineDisposed("Plugin released")) }
        guard case .success(let props) = parsed else {
          return reply.error(.invalidArguments("propsJson is not a JSON object"))
        }
        guard let runtime = self.registry.runtime(forView: viewId) else {
          return reply.error(.unknownView(viewId))
        }
        if let error = runtime.updateProps(viewId: viewId, props: props) {
          reply.error(error)
        } else {
          reply.success(nil)
        }
      }
    }
  }
}

// MARK: - native -> Dart

extension FlutterReactEmbedPlugin: RuntimeEvents {
  func runtime(_ runtimeId: String, didEmitFrame frame: String) {
    messages.invokeMethod("onFrame", arguments: ["runtimeId": runtimeId, "frame": frame])
  }

  func runtime(_ runtimeId: String, didChangeState state: String) {
    messages.invokeMethod("onRuntimeState", arguments: ["runtimeId": runtimeId, "state": state])
  }

  func runtime(_ runtimeId: String, didFail message: String, stack: String?, fatal: Bool) {
    messages.invokeMethod(
      "onRuntimeError",
      arguments: [
        "runtimeId": runtimeId, "message": message, "stack": stack ?? NSNull(), "fatal": fatal,
      ])
  }
}

/// Owns live runtimes and the platform-view -> runtime binding. Main thread only.
final class RuntimeRegistry {
  private var runtimes: [String: WebRuntime] = [:]
  private var viewToRuntime: [Int64: String] = [:]

  func add(_ runtime: WebRuntime) { runtimes[runtime.id] = runtime }

  func runtime(_ id: String) -> WebRuntime? { runtimes[id] }

  @discardableResult
  func remove(_ id: String) -> WebRuntime? {
    viewToRuntime = viewToRuntime.filter { $0.value != id }
    return runtimes.removeValue(forKey: id)
  }

  func bind(viewId: Int64, runtimeId: String) { viewToRuntime[viewId] = runtimeId }

  func unbind(viewId: Int64) { viewToRuntime.removeValue(forKey: viewId) }

  func runtime(forView viewId: Int64) -> WebRuntime? {
    viewToRuntime[viewId].flatMap { runtimes[$0] }
  }

  func runtimeRetaining(_ cacheKey: String) -> WebRuntime? {
    runtimes.values.first { $0.retainedCacheKey == cacheKey }
  }

  func disposeAll() {
    let all = Array(runtimes.values)
    runtimes.removeAll()
    viewToRuntime.removeAll()
    all.forEach { $0.dispose() }
  }
}

/// Guards a `FlutterResult` against double replies.
final class SingleReply {
  private var result: FlutterResult?

  init(_ result: @escaping FlutterResult) { self.result = result }

  func success(_ value: Any?) { take()?(value) }

  func error(_ error: FREError) { take()?(error.flutterError) }

  private func take() -> FlutterResult? {
    defer { result = nil }
    if result == nil { NSLog("[FlutterReactEmbed] ignored a second reply to the same call") }
    return result
  }
}

extension FREError {
  var flutterError: FlutterError { FlutterError(code: code, message: message, details: nil) }
}
