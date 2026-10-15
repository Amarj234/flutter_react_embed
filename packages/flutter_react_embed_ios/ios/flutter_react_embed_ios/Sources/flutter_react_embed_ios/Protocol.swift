import Foundation
import UIKit

/// Wire constants shared with `MethodChannelFlutterReactEmbed` (Dart) and the
/// JS bridge package. Changing any value here is a protocol break.
enum FREProtocol {
  static let controlChannel = "dev.flutter_react_embed/control"
  static let messageChannel = "dev.flutter_react_embed/messages"
  static let viewTypeWeb = "dev.flutter_react_embed/view/web"
  static let viewTypeReactNative = "dev.flutter_react_embed/view/react_native"

  static let engineWeb = "web"
  static let engineReactNative = "react_native"

  /// Custom scheme the bundle is served from. Origin: `fre-app://bundle`.
  static let scheme = "fre-app"
  static let host = "bundle"
  static let entryURL = URL(string: "\(scheme)://\(host)/")!

  /// Script message handler names (the listener array). `freNative` carries
  /// bridge frames; `freError` carries uncaught JS errors and rejections.
  static let frameHandler = "freNative"
  static let errorHandler = "freError"

  /// React Native module name (`NativeModules.FlutterReactEmbed`) and its event.
  static let rnModule = "FlutterReactEmbed"
  static let rnFrameEvent = "freFrame"
  /// Initial-props key carrying `{runtimeId, viewId, contractVersion, platform, cacheKey}`.
  static let rnMetaProp = "__fre"

  static let stateReady = "ready"
  static let stateCrashed = "crashed"

  static let bootTimeout: TimeInterval = 20
  static let maxPendingOutbound = 256

  /// Builds a host -> JS lifecycle notification (`$/mount`, `$/updateProps`,
  /// `$/unmount`). Returns nil only if `params` is not JSON-serializable.
  static func notification(_ method: String, _ params: [String: Any]) -> String? {
    let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
    guard JSONSerialization.isValidJSONObject(message),
      let data = try? JSONSerialization.data(withJSONObject: message)
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Parses a JSON object produced by Dart's `jsonEncode`.
  static func parseObject(_ json: String) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
    guard let object = value as? [String: Any] else {
      throw FREError.invalidArguments("expected a JSON object")
    }
    return object
  }
}

/// Errors surfaced to Dart as `PlatformException(code, message)`.
enum FREError: Error {
  case invalidArguments(String)
  case unsupportedEngine(String)
  case bundleNotFound(String)
  case bundleIntegrity(expected: String, actual: String, file: String = "index.html")
  case engineInitFailed(String)
  case bootTimeout
  case engineDisposed(String)
  case unknownRuntime(String)
  case unknownView(Int64)
  case payloadTooLarge(Int, limit: Int)
  case queueFull

  var code: String {
    switch self {
    case .invalidArguments: return "INVALID_ARGUMENTS"
    case .unsupportedEngine: return "UNSUPPORTED_ENGINE"
    case .bundleNotFound: return "BUNDLE_NOT_FOUND"
    case .bundleIntegrity: return "BUNDLE_INTEGRITY"
    case .engineInitFailed: return "ENGINE_INIT_FAILED"
    case .bootTimeout: return "BOOT_TIMEOUT"
    case .engineDisposed: return "ENGINE_DISPOSED"
    case .unknownRuntime: return "UNKNOWN_RUNTIME"
    case .unknownView: return "UNKNOWN_VIEW"
    case .payloadTooLarge: return "PAYLOAD_TOO_LARGE"
    case .queueFull: return "QUEUE_FULL"
    }
  }

  var message: String {
    switch self {
    case .invalidArguments(let detail): return detail
    case .unsupportedEngine(let detail): return detail
    case .bundleNotFound(let path): return "No \(path) in the app's Flutter assets"
    case .bundleIntegrity(let expected, let actual, let file):
      return "\(file) sha256 is \(actual), expected \(expected)"
    case .engineInitFailed(let detail): return detail
    case .bootTimeout:
      return "JS did not send its first frame within \(Int(FREProtocol.bootTimeout)) s"
    case .engineDisposed(let detail): return detail
    case .unknownRuntime(let id): return "Runtime \(id) does not exist"
    case .unknownView(let id): return "No React surface for view \(id)"
    case .payloadTooLarge(let bytes, let limit): return "Frame is \(bytes) bytes; limit is \(limit)"
    case .queueFull: return "Too many frames queued before JS became ready"
    }
  }
}

/// Parsed `initializeEngine` arguments.
struct RuntimeConfig {
  let engine: String
  let bundle: String
  let bundleSha256: String?
  let contractVersion: String
  let enableDebugging: Bool
  let maxMessageBytes: Int

  init(arguments: Any?) throws {
    guard let map = arguments as? [String: Any] else {
      throw FREError.invalidArguments("initializeEngine expects a map")
    }
    guard let engine = map["engine"] as? String else {
      throw FREError.invalidArguments("\"engine\" must be a string")
    }
    guard let bundle = (map["bundle"] as? String)?.trimmingCharacters(in: .whitespaces), !bundle.isEmpty
    else {
      throw FREError.invalidArguments("\"bundle\" must be a non-empty string")
    }
    let maxBytes = (map["maxMessageBytes"] as? NSNumber)?.intValue ?? (1 << 20)
    guard maxBytes >= 1024 else {
      throw FREError.invalidArguments("\"maxMessageBytes\" must be >= 1024")
    }
    self.engine = engine
    self.bundle = bundle
    self.bundleSha256 = (map["bundleSha256"] as? String)?.lowercased()
    self.contractVersion = map["contractVersion"] as? String ?? "1.0.0"
    self.enableDebugging = map["enableDebugging"] as? Bool ?? false
    self.maxMessageBytes = maxBytes
  }
}

/// Parsed platform-view creation params (see `ReactSurfaceCreationParams`).
struct SurfaceParams {
  let runtimeId: String
  let engine: String
  let moduleName: String
  let initialPropsJson: String
  let cacheKey: String?

  init(arguments: Any?) throws {
    guard let map = arguments as? [String: Any],
      let runtimeId = map["runtimeId"] as? String,
      let engine = map["engine"] as? String,
      let moduleName = map["moduleName"] as? String
    else {
      throw FREError.invalidArguments("creation params require runtimeId, engine and moduleName")
    }
    self.runtimeId = runtimeId
    self.engine = engine
    self.moduleName = moduleName
    self.initialPropsJson = map["initialPropsJson"] as? String ?? "{}"
    self.cacheKey = map["cacheKey"] as? String
  }
}

/// Thread allocation for the plugin.
///
/// - Main queue: Flutter channels, every `WKWebView` call and view attachment.
///   WebKit and Flutter both require the main thread for these.
/// - `bridge`: serial queue for frame validation and props parsing. Serial
///   execution preserves message order.
/// - `io`: concurrent queue for bundle verification and asset reads.
final class EmbedQueues {
  let bridge = DispatchQueue(label: "dev.flutterreactembed.bridge", qos: .userInitiated)
  let io = DispatchQueue(
    label: "dev.flutterreactembed.io", qos: .userInitiated, attributes: .concurrent)

  /// Runs `work` on main, inline when already there.
  static func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
  }
}

/// One JavaScript runtime as seen by the plugin and its platform views.
/// Implemented by `WebRuntime` and, with the `ReactNative` subspec,
/// `NativeRuntime`. Main thread only.
protocol EmbedRuntime: AnyObject {
  var id: String { get }
  /// `FREProtocol.engineWeb` or `FREProtocol.engineReactNative`.
  var engine: String { get }
  /// Whether a detached surface is retained under `cacheKey`.
  func retains(_ cacheKey: String) -> Bool
  func deliverFromDart(_ frame: String, completion: @escaping (FREError?) -> Void)
  /// Shows a surface for `params` in `container`. Returns an error message, or nil.
  func attach(viewId: Int64, container: UIView, params: SurfaceParams) -> String?
  func detach(viewId: Int64, cacheKey: String?)
  func evictCached(_ cacheKey: String)
  func updateProps(viewId: Int64, props: [String: Any]) -> FREError?
  /// Releases every resource. Idempotent.
  func dispose()
}

/// Receives runtime output. Always invoked on the main thread.
protocol RuntimeEvents: AnyObject {
  func runtime(_ runtimeId: String, didEmitFrame frame: String)
  func runtime(_ runtimeId: String, didChangeState state: String)
  func runtime(_ runtimeId: String, didFail message: String, stack: String?, fatal: Bool)
}
