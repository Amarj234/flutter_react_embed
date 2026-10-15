import Foundation
import UIKit
import WebKit

/// Forwards script messages to a weakly held receiver.
///
/// `WKUserContentController` retains its handlers strongly. Registering the
/// runtime directly would form runtime -> webView -> configuration ->
/// controller -> runtime, a cycle that leaks the whole WebView.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  weak var receiver: WKScriptMessageHandler?

  init(_ receiver: WKScriptMessageHandler) {
    self.receiver = receiver
  }

  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    receiver?.userContentController(controller, didReceive: message)
  }
}

/// One JavaScript runtime: a `WKWebView` document hosting a production React SPA.
///
/// ### Threading
/// All state is confined to the main thread, where WebKit delivers script
/// messages and navigation callbacks. Frames hop to the serial `bridge` queue
/// for validation and back to main for delivery, preserving order.
///
/// ### Lifecycle
/// The web view is created at boot, before any platform view exists, so the
/// document is ready when the view mounts. `attach` moves it into a platform
/// view's container; `detach` removes it; `dispose` tears it down. One
/// document is one surface, so a runtime is attached to at most one view.
///
/// ### JS contract
/// - `window.__FRE_BOOT__`: `{runtimeId, contractVersion, transport, platform}`.
/// - JS -> host: `window.__freNative.postMessage(frameString)` (installed by
///   the boot script over `webkit.messageHandlers.freNative`).
/// - host -> JS: `window.__freReceive(frameString)`, which JS must define
///   before posting its first frame. The first frame is the readiness signal.
/// - Host lifecycle notifications: `$/mount`, `$/updateProps`, `$/unmount`.
final class WebRuntime: NSObject {
  private enum Phase { case created, booting, ready, crashed, disposed }

  let id: String
  private let config: RuntimeConfig
  private let bundleRoot: URL
  private let queues: EmbedQueues
  private weak var events: RuntimeEvents?

  private var phase = Phase.created
  private(set) var webView: WKWebView?
  private var pendingOutbound: [String] = []
  private var bootCompletion: ((FREError?) -> Void)?
  private var bootTimer: DispatchWorkItem?

  /// Platform view currently showing this runtime, if any.
  private(set) var attachedViewId: Int64?
  /// Cache key under which JS keeps the React tree mounted while detached.
  private(set) var retainedCacheKey: String?

  init(id: String, config: RuntimeConfig, bundleRoot: URL, queues: EmbedQueues, events: RuntimeEvents) {
    self.id = id
    self.config = config
    self.bundleRoot = bundleRoot
    self.queues = queues
    self.events = events
    super.init()
  }

  deinit {
    // Normally disposed explicitly; this is the backstop. Swift runs deinit on
    // whichever thread released the last reference, so hand the web view to
    // main for teardown.
    if let webView {
      DispatchQueue.main.async { WebRuntime.tearDown(webView) }
    }
  }

  // MARK: - Boot

  /// Creates the web view and loads the bundle. `completion` receives nil once
  /// JS has sent its first frame, or the reason boot failed.
  func boot(completion: @escaping (FREError?) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    precondition(phase == .created, "Runtime \(id) already booted")
    phase = .booting
    bootCompletion = completion

    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(
      BundleSchemeHandler(root: bundleRoot, io: queues.io), forURLScheme: FREProtocol.scheme)
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.allowsInlineMediaPlayback = true

    let contentController = WKUserContentController()
    contentController.addUserScript(
      WKUserScript(source: bootScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
    // The listener array: one weak proxy per handler name, page content world.
    for name in [FREProtocol.frameHandler, FREProtocol.errorHandler] {
      contentController.add(WeakScriptMessageHandler(self), contentWorld: .page, name: name)
    }
    configuration.userContentController = contentController

    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = self
    view.isOpaque = false
    view.backgroundColor = .clear
    view.scrollView.backgroundColor = .clear
    view.scrollView.contentInsetAdjustmentBehavior = .never
    if #available(iOS 16.4, *) {
      view.isInspectable = config.enableDebugging
    }
    webView = view

    let timer = DispatchWorkItem { [weak self] in self?.failBoot(.bootTimeout) }
    bootTimer = timer
    DispatchQueue.main.asyncAfter(deadline: .now() + FREProtocol.bootTimeout, execute: timer)
    view.load(URLRequest(url: FREProtocol.entryURL))
  }

  private func bootScript() -> String {
    let boot: [String: Any] = [
      "runtimeId": id,
      "contractVersion": config.contractVersion,
      "transport": "webkit",
      "platform": "ios",
    ]
    let bootJson =
      (try? JSONSerialization.data(withJSONObject: boot)).flatMap { String(data: $0, encoding: .utf8) }
      ?? "{}"
    return """
      (function(){
        if (window.__FRE_BOOT__) return;
        var h = window.webkit.messageHandlers;
        Object.defineProperty(window, '__FRE_BOOT__', { value: Object.freeze(\(bootJson)) });
        Object.defineProperty(window, '__freNative', { value: Object.freeze({
          postMessage: function (frame) { h.\(FREProtocol.frameHandler).postMessage(String(frame)); }
        }) });
        function report(message, stack) {
          try { h.\(FREProtocol.errorHandler).postMessage({ message: String(message), stack: stack ? String(stack) : null }); } catch (_) {}
        }
        window.addEventListener('error', function (e) {
          report(e.message, e.error && e.error.stack ? e.error.stack : (e.filename + ':' + e.lineno));
        });
        window.addEventListener('unhandledrejection', function (e) {
          var r = e.reason;
          report('Unhandled promise rejection: ' + (r && r.message ? r.message : r), r && r.stack);
        });
      })();
      """
  }

  // MARK: - JS -> Dart

  private func receiveFromJs(_ frame: String) {
    let limit = config.maxMessageBytes
    queues.bridge.async { [weak self] in
      let bytes = frame.utf8.count
      DispatchQueue.main.async {
        guard let self, self.phase == .booting || self.phase == .ready else { return }
        if bytes > limit {
          self.events?.runtime(
            self.id, didFail: "Dropped a \(bytes)-byte frame from JS (limit \(limit))", stack: nil,
            fatal: false)
          return
        }
        self.deliverInbound(frame)
      }
    }
  }

  private func deliverInbound(_ frame: String) {
    if phase == .booting {
      // First frame = JS bridge is ready: flush queued frames, finish boot.
      phase = .ready
      bootTimer?.cancel()
      bootTimer = nil
      flushPendingOutbound()
      bootCompletion?(nil)
      bootCompletion = nil
      events?.runtime(id, didChangeState: FREProtocol.stateReady)
    }
    events?.runtime(id, didEmitFrame: frame)
  }

  // MARK: - Dart -> JS

  /// Validates `frame` off the main thread, then queues or posts it.
  func deliverFromDart(_ frame: String, completion: @escaping (FREError?) -> Void) {
    let limit = config.maxMessageBytes
    queues.bridge.async { [weak self] in
      let bytes = frame.utf8.count
      DispatchQueue.main.async {
        guard let self else { return completion(.engineDisposed("Runtime was released")) }
        if bytes > limit { return completion(.payloadTooLarge(bytes, limit: limit)) }
        switch self.phase {
        case .crashed, .disposed: completion(.engineDisposed("Runtime \(self.id) is not running"))
        default: completion(self.postToJs(frame))
        }
      }
    }
  }

  @discardableResult
  private func postToJs(_ frame: String) -> FREError? {
    guard let webView else { return .engineDisposed("Runtime \(id) has no web view") }
    guard phase == .ready else {
      guard pendingOutbound.count < FREProtocol.maxPendingOutbound else { return .queueFull }
      pendingOutbound.append(frame)
      return nil
    }
    // Arguments are passed as JS values, never spliced into source.
    webView.callAsyncJavaScript(
      "window.__freReceive(frame);", arguments: ["frame": frame], in: nil, in: .page
    ) { [weak self] result in
      if case .failure(let error) = result, let self {
        self.events?.runtime(
          self.id, didFail: "Delivering a frame to JS failed: \(error.localizedDescription)",
          stack: nil, fatal: false)
      }
    }
    return nil
  }

  private func flushPendingOutbound() {
    let frames = pendingOutbound
    pendingOutbound.removeAll()
    frames.forEach { postToJs($0) }
  }

  // MARK: - Surfaces

  /// Moves the web view into `container` and mounts `params` in JS.
  func attach(viewId: Int64, container: UIView, params: SurfaceParams) -> String? {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let webView else { return "Runtime \(id) is not available" }
    if let current = attachedViewId, current != viewId {
      return "Runtime \(id) is already attached to view \(current); a web document can only be shown once"
    }
    let props: [String: Any]
    do {
      props = try FREProtocol.parseObject(params.initialPropsJson)
    } catch {
      return "initialPropsJson is not a JSON object"
    }

    webView.removeFromSuperview()
    webView.frame = container.bounds
    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.addSubview(webView)
    attachedViewId = viewId

    let reattached = params.cacheKey != nil && params.cacheKey == retainedCacheKey
    retainedCacheKey = params.cacheKey
    if let frame = FREProtocol.notification(
      "$/mount",
      [
        "viewId": viewId,
        "moduleName": params.moduleName,
        "props": props,
        "cacheKey": params.cacheKey ?? NSNull(),
        "reattached": reattached,
      ])
    {
      postToJs(frame)
    }
    return nil
  }

  /// Removes the web view from its container. With a `cacheKey`, JS keeps the
  /// React tree mounted for a later reattach; otherwise it is unmounted.
  func detach(viewId: Int64, cacheKey: String?) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard attachedViewId == viewId else { return }
    attachedViewId = nil
    webView?.removeFromSuperview()
    if cacheKey == nil {
      retainedCacheKey = nil
      if let frame = FREProtocol.notification("$/unmount", ["viewId": viewId]) { postToJs(frame) }
    }
  }

  /// Drops the retained React tree for `cacheKey` if it is not on screen.
  func evictCached(_ cacheKey: String) {
    guard retainedCacheKey == cacheKey, attachedViewId == nil else { return }
    retainedCacheKey = nil
    if let frame = FREProtocol.notification("$/unmount", ["cacheKey": cacheKey]) { postToJs(frame) }
  }

  func updateProps(viewId: Int64, props: [String: Any]) -> FREError? {
    guard attachedViewId == viewId else { return .unknownView(viewId) }
    guard let frame = FREProtocol.notification("$/updateProps", ["viewId": viewId, "props": props])
    else { return .invalidArguments("props are not JSON-serializable") }
    return postToJs(frame)
  }

  // MARK: - Failure and teardown

  private func failBoot(_ error: FREError) {
    guard let completion = bootCompletion else { return }
    bootCompletion = nil
    bootTimer?.cancel()
    bootTimer = nil
    completion(error)
  }

  private func contentProcessTerminated() {
    if phase == .booting {
      failBoot(.engineInitFailed("WebContent process terminated during boot"))
    } else {
      events?.runtime(id, didFail: "WebContent process terminated", stack: nil, fatal: true)
      events?.runtime(id, didChangeState: FREProtocol.stateCrashed)
    }
    phase = .crashed
    releaseWebView()
  }

  /// Releases every resource. Idempotent.
  func dispose() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard phase != .disposed else { return }
    // Mark first: the boot callback below re-enters dispose().
    phase = .disposed
    failBoot(.engineDisposed("Runtime \(id) was disposed during boot"))
    pendingOutbound.removeAll()
    attachedViewId = nil
    retainedCacheKey = nil
    releaseWebView()
  }

  private func releaseWebView() {
    guard let view = webView else { return }
    webView = nil
    WebRuntime.tearDown(view)
  }

  /// Breaks every reference WebKit holds toward the plugin and unloads the page.
  private static func tearDown(_ view: WKWebView) {
    view.stopLoading()
    view.navigationDelegate = nil
    view.uiDelegate = nil
    let controller = view.configuration.userContentController
    controller.removeAllScriptMessageHandlers()
    controller.removeAllUserScripts()
    view.removeFromSuperview()
    view.loadHTMLString("", baseURL: nil)
  }
}

// MARK: - WKScriptMessageHandler

extension WebRuntime: WKScriptMessageHandler {
  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    // Only our bundle's main frame may talk to the host.
    let origin = message.frameInfo.securityOrigin
    guard message.frameInfo.isMainFrame, origin.protocol == FREProtocol.scheme,
      origin.host == FREProtocol.host
    else { return }

    switch message.name {
    case FREProtocol.frameHandler:
      guard let frame = message.body as? String else { return }
      receiveFromJs(frame)
    case FREProtocol.errorHandler:
      guard phase == .booting || phase == .ready, let body = message.body as? [String: Any] else {
        return
      }
      events?.runtime(
        id, didFail: body["message"] as? String ?? "Unknown JS error",
        stack: body["stack"] as? String, fatal: false)
    default:
      break
    }
  }
}

// MARK: - WKNavigationDelegate

extension WebRuntime: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = action.request.url else { return decisionHandler(.cancel) }
    if url.scheme == FREProtocol.scheme, url.host == FREProtocol.host {
      return decisionHandler(.allow)
    }
    let isWeb = url.scheme == "https" || url.scheme == "http"
    // Third-party subframes (embeds) may load; the bridge ignores non-main frames.
    if isWeb, action.targetFrame?.isMainFrame == false {
      return decisionHandler(.allow)
    }
    // Main-frame navigation away from the bundle: open user taps externally.
    if isWeb, action.navigationType == .linkActivated {
      UIApplication.shared.open(url)
    }
    decisionHandler(.cancel)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    failBoot(.engineInitFailed("Failed to load bundle: \(error.localizedDescription)"))
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failBoot(.engineInitFailed("Bundle failed while loading: \(error.localizedDescription)"))
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    contentProcessTerminated()
  }
}
