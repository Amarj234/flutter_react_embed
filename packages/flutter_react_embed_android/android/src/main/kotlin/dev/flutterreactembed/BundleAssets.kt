package dev.flutterreactembed

import android.content.res.AssetManager
import android.webkit.WebResourceResponse
import androidx.annotation.WorkerThread
import androidx.webkit.WebViewAssetLoader
import java.io.ByteArrayInputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest

/** Result of checking a web bundle before a runtime boots. */
internal sealed interface BundleCheck {
    data object Ok : BundleCheck
    data class NotFound(val path: String) : BundleCheck
    data class IntegrityMismatch(val expected: String, val actual: String) : BundleCheck
    data class Unreadable(val reason: String) : BundleCheck
}

internal object BundleVerifier {
    /**
     * Verifies that `<assetDir>/index.html` exists and, when [expectedSha256]
     * is set, that its SHA-256 matches. Pinning index.html pins the whole
     * build, because it references content-hashed asset file names.
     */
    @WorkerThread
    fun verify(assets: AssetManager, assetDir: String, expectedSha256: String?): BundleCheck {
        val indexPath = "$assetDir/index.html"
        return try {
            assets.open(indexPath).use { stream ->
                if (expectedSha256 == null) {
                    BundleCheck.Ok
                } else {
                    val actual = sha256Hex(stream)
                    if (actual == expectedSha256) BundleCheck.Ok else BundleCheck.IntegrityMismatch(expectedSha256, actual)
                }
            }
        } catch (_: FileNotFoundException) {
            BundleCheck.NotFound(indexPath)
        } catch (e: IOException) {
            BundleCheck.Unreadable(e.message ?: e.javaClass.simpleName)
        }
    }

    private fun sha256Hex(stream: InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val read = stream.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}

/**
 * Serves one bundle directory from the APK's Flutter assets.
 *
 * Registered under "/" on [Protocol.ORIGIN], so SPAs built with the default
 * absolute base path (`/assets/index-<hash>.js`) work unchanged. Invoked by
 * WebView on its own background thread.
 *
 * - Path traversal (`..`, `.`, backslashes) is rejected with 404.
 * - Extensionless misses fall back to `index.html` for client-side routing.
 * - Every other miss is a real 404, never a network request.
 * - When [bootScript] is non-null (WebView without document-start script
 *   support), it is inlined at the top of `index.html`'s `<head>`.
 */
internal class BundlePathHandler(
    private val assets: AssetManager,
    private val assetDir: String,
    private val bootScript: String?,
) : WebViewAssetLoader.PathHandler {

    @WorkerThread
    override fun handle(path: String): WebResourceResponse {
        val relative = sanitize(path) ?: return notFound()
        val target = if (relative.isEmpty() || relative.endsWith("/")) "${relative}index.html" else relative
        open(target)?.let { return respond(target, it) }

        val isRoute = !target.substringAfterLast('/').contains('.')
        if (isRoute) {
            open("index.html")?.let { return respond("index.html", it) }
        }
        return notFound()
    }

    private fun open(relative: String): InputStream? = try {
        assets.open("$assetDir/$relative")
    } catch (_: IOException) {
        null
    }

    private fun respond(path: String, stream: InputStream): WebResourceResponse {
        val mime = mimeTypeOf(path)
        val body = if (path == "index.html" && bootScript != null) injectBootScript(stream) else stream
        val encoding = if (mime.startsWith("text/") || mime == "application/json" || mime == "image/svg+xml") "utf-8" else null
        return WebResourceResponse(mime, encoding, 200, "OK", HEADERS, body)
    }

    private fun injectBootScript(stream: InputStream): InputStream {
        val html = stream.use { it.readBytes().toString(Charsets.UTF_8) }
        val tag = "<script>$bootScript</script>"
        val head = Regex("<head[^>]*>", RegexOption.IGNORE_CASE).find(html)
        val patched = if (head != null) html.replaceRange(head.range.last + 1, head.range.last + 1, tag) else tag + html
        return ByteArrayInputStream(patched.toByteArray(Charsets.UTF_8))
    }

    private fun notFound() = WebResourceResponse(
        "text/plain", "utf-8", 404, "Not Found", HEADERS, ByteArrayInputStream(ByteArray(0)),
    )

    companion object {
        // Assets come from the APK, so revalidation is free and avoids serving
        // stale non-hashed files (favicon, manifest) after an app update.
        private val HEADERS = mapOf(
            "Cache-Control" to "no-cache",
            "X-Content-Type-Options" to "nosniff",
        )

        private val MIME_TYPES = mapOf(
            "html" to "text/html",
            "js" to "text/javascript",
            "mjs" to "text/javascript",
            "css" to "text/css",
            "json" to "application/json",
            "map" to "application/json",
            "webmanifest" to "application/manifest+json",
            "svg" to "image/svg+xml",
            "png" to "image/png",
            "jpg" to "image/jpeg",
            "jpeg" to "image/jpeg",
            "gif" to "image/gif",
            "webp" to "image/webp",
            "avif" to "image/avif",
            "ico" to "image/x-icon",
            "woff" to "font/woff",
            "woff2" to "font/woff2",
            "ttf" to "font/ttf",
            "otf" to "font/otf",
            "wasm" to "application/wasm",
            "txt" to "text/plain",
        )

        fun mimeTypeOf(path: String): String =
            MIME_TYPES[path.substringAfterLast('.', "").lowercase()] ?: "application/octet-stream"

        /** Normalizes a request path, or returns null if it tries to escape the bundle. */
        fun sanitize(path: String): String? {
            if (path.contains('\\') || path.contains('\u0000')) return null
            val segments = path.split('/')
            if (segments.any { it == ".." || it == "." }) return null
            return path.trimStart('/')
        }
    }
}
