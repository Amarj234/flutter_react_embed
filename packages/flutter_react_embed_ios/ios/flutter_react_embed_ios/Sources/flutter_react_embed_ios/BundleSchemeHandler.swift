import CryptoKit
import Foundation
import WebKit

/// Verifies a web bundle before a runtime boots.
enum BundleVerifier {
  /// Checks that `index.html` exists in `root` and, when `expectedSha256` is
  /// set, that its SHA-256 matches. Pinning index.html pins the whole build,
  /// because it references content-hashed asset file names. Call off main.
  static func verify(root: URL, expectedSha256: String?) -> Result<Void, FREError> {
    let index = root.appendingPathComponent("index.html")
    guard let data = try? Data(contentsOf: index, options: .mappedIfSafe) else {
      return .failure(.bundleNotFound(index.lastPathComponent))
    }
    guard let expected = expectedSha256 else { return .success(()) }
    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return actual == expected
      ? .success(()) : .failure(.bundleIntegrity(expected: expected, actual: actual))
  }
}

/// Serves one bundle directory over `fre-app://bundle/`.
///
/// - File reads run on the `io` queue; WebKit callbacks are delivered on main.
/// - A task WebKit has stopped is never touched again. Calling into a stopped
///   `WKURLSchemeTask` raises an Objective-C exception, so in-flight tasks are
///   tracked and checked before every callback.
/// - Path traversal is rejected; extensionless misses fall back to
///   `index.html` for client-side routing; other misses are 404s.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
  private let root: URL
  private let io: DispatchQueue
  /// Tasks WebKit started and has not stopped. Main-thread confined.
  private var activeTasks = Set<ObjectIdentifier>()

  init(root: URL, io: DispatchQueue) {
    self.root = root.standardizedFileURL
    self.io = io
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    let taskId = ObjectIdentifier(urlSchemeTask)
    activeTasks.insert(taskId)
    guard let url = urlSchemeTask.request.url else {
      activeTasks.remove(taskId)
      urlSchemeTask.didFailWithError(URLError(.badURL))
      return
    }
    let root = self.root
    io.async { [weak self] in
      let response = BundleSchemeHandler.load(url: url, root: root)
      DispatchQueue.main.async {
        guard let self, self.activeTasks.remove(taskId) != nil else { return }
        let http = HTTPURLResponse(
          url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
          headerFields: [
            "Content-Type": response.mimeType,
            "Content-Length": String(response.body.count),
            "Cache-Control": "no-cache",
            "X-Content-Type-Options": "nosniff",
          ])!
        urlSchemeTask.didReceive(http)
        urlSchemeTask.didReceive(response.body)
        urlSchemeTask.didFinish()
      }
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    activeTasks.remove(ObjectIdentifier(urlSchemeTask))
  }

  // MARK: - File resolution (io queue)

  private struct Response {
    let status: Int
    let mimeType: String
    let body: Data
  }

  private static func load(url: URL, root: URL) -> Response {
    guard let relative = sanitize(url.path) else { return notFound }
    let target = relative.isEmpty || relative.hasSuffix("/") ? relative + "index.html" : relative
    if let body = read(target, root: root) {
      return Response(status: 200, mimeType: mimeType(of: target), body: body)
    }
    let isRoute = !(target.split(separator: "/").last ?? "").contains(".")
    if isRoute, let body = read("index.html", root: root) {
      return Response(status: 200, mimeType: "text/html; charset=utf-8", body: body)
    }
    return notFound
  }

  private static let notFound = Response(status: 404, mimeType: "text/plain", body: Data())

  private static func read(_ relative: String, root: URL) -> Data? {
    let file = root.appendingPathComponent(relative).standardizedFileURL
    // Belt and braces: the resolved file must still live under the root.
    guard file.path.hasPrefix(root.path + "/") else { return nil }
    return try? Data(contentsOf: file, options: .mappedIfSafe)
  }

  /// Normalizes a request path, or returns nil if it tries to escape the bundle.
  static func sanitize(_ path: String) -> String? {
    if path.contains("\\") || path.contains("\0") { return nil }
    let segments = path.split(separator: "/", omittingEmptySubsequences: false)
    if segments.contains(where: { $0 == ".." || $0 == "." }) { return nil }
    return String(path.drop(while: { $0 == "/" }))
  }

  private static let mimeTypes: [String: String] = [
    "html": "text/html; charset=utf-8",
    "js": "text/javascript; charset=utf-8",
    "mjs": "text/javascript; charset=utf-8",
    "css": "text/css; charset=utf-8",
    "json": "application/json",
    "map": "application/json",
    "webmanifest": "application/manifest+json",
    "svg": "image/svg+xml",
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "gif": "image/gif",
    "webp": "image/webp",
    "avif": "image/avif",
    "ico": "image/x-icon",
    "woff": "font/woff",
    "woff2": "font/woff2",
    "ttf": "font/ttf",
    "otf": "font/otf",
    "wasm": "application/wasm",
    "txt": "text/plain; charset=utf-8",
  ]

  static func mimeType(of path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    return mimeTypes[ext] ?? "application/octet-stream"
  }
}
