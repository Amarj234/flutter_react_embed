package dev.flutterreactembed

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.AnyThread
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicInteger

/**
 * Wire constants shared with `MethodChannelFlutterReactEmbed` (Dart) and the
 * JS bridge package. Changing any value here is a protocol break.
 */
internal object Protocol {
    const val CONTROL_CHANNEL = "dev.flutter_react_embed/control"
    const val MESSAGE_CHANNEL = "dev.flutter_react_embed/messages"
    const val VIEW_TYPE_WEB = "dev.flutter_react_embed/view/web"

    const val ENGINE_WEB = "web"
    const val ENGINE_REACT_NATIVE = "react_native"

    /** Name of the JS object exposing `postMessage(frame)` to the page. */
    const val JS_OBJECT = "__freNative"

    /** Origin every bundle is served from (intercepted, never hits the network). */
    const val ASSET_HOST = "appassets.androidplatform.net"
    const val ORIGIN = "https://$ASSET_HOST"

    // Error codes surfaced to Dart as PlatformException.code.
    const val E_INVALID_ARGUMENTS = "INVALID_ARGUMENTS"
    const val E_UNSUPPORTED_ENGINE = "UNSUPPORTED_ENGINE"
    const val E_BUNDLE_NOT_FOUND = "BUNDLE_NOT_FOUND"
    const val E_BUNDLE_INTEGRITY = "BUNDLE_INTEGRITY"
    const val E_ENGINE_INIT_FAILED = "ENGINE_INIT_FAILED"
    const val E_BOOT_TIMEOUT = "BOOT_TIMEOUT"
    const val E_ENGINE_DISPOSED = "ENGINE_DISPOSED"
    const val E_UNKNOWN_RUNTIME = "UNKNOWN_RUNTIME"
    const val E_UNKNOWN_VIEW = "UNKNOWN_VIEW"
    const val E_PAYLOAD_TOO_LARGE = "PAYLOAD_TOO_LARGE"
    const val E_QUEUE_FULL = "QUEUE_FULL"

    // Runtime states, mirroring Dart's ReactRuntimeState names.
    const val STATE_READY = "ready"
    const val STATE_PAUSED = "paused"
    const val STATE_CRASHED = "crashed"

    /** How long JS may take to send its first frame after the page starts loading. */
    const val BOOT_TIMEOUT_MS = 20_000L

    /** Frames queued for JS before it signalled readiness. */
    const val MAX_PENDING_OUTBOUND = 256

    /**
     * Builds a host -> JS protocol notification (`$/mount`, `$/updateProps`,
     * `$/unmount`). The `$/` prefix keeps these out of Dart's event stream and
     * marks them as host lifecycle messages for the JS bridge.
     */
    fun notification(method: String, params: JSONObject): String =
        JSONObject()
            .put("jsonrpc", "2.0")
            .put("method", method)
            .put("params", params)
            .toString()

    /** Parses a JSON object produced by Dart's `jsonEncode`, or throws. */
    fun parseObject(json: String): JSONObject = JSONObject(json)
}

/** Parsed `initializeEngine` arguments. */
internal data class RuntimeConfig(
    val engine: String,
    val bundle: String,
    val bundleSha256: String?,
    val contractVersion: String,
    val enableDebugging: Boolean,
    val maxMessageBytes: Int,
) {
    companion object {
        /** @throws IllegalArgumentException when a field is missing or mistyped. */
        fun fromArguments(arguments: Any?): RuntimeConfig {
            val map = arguments as? Map<*, *>
                ?: throw IllegalArgumentException("initializeEngine expects a map")
            fun string(key: String): String = map[key] as? String
                ?: throw IllegalArgumentException("\"$key\" must be a string")
            val bundle = string("bundle").trim()
            require(bundle.isNotEmpty()) { "\"bundle\" must not be empty" }
            val maxBytes = (map["maxMessageBytes"] as? Number)?.toInt() ?: (1 shl 20)
            require(maxBytes >= 1024) { "\"maxMessageBytes\" must be >= 1024" }
            return RuntimeConfig(
                engine = string("engine"),
                bundle = bundle,
                bundleSha256 = (map["bundleSha256"] as? String)?.lowercase(),
                contractVersion = map["contractVersion"] as? String ?: "1.0.0",
                enableDebugging = map["enableDebugging"] as? Boolean ?: false,
                maxMessageBytes = maxBytes,
            )
        }
    }
}

/** Parsed platform-view creation params (see `ReactSurfaceCreationParams`). */
internal data class SurfaceParams(
    val runtimeId: String,
    val engine: String,
    val moduleName: String,
    val initialPropsJson: String,
    val cacheKey: String?,
) {
    companion object {
        fun fromArguments(arguments: Any?): SurfaceParams {
            val map = arguments as? Map<*, *>
                ?: throw IllegalArgumentException("creation params must be a map")
            fun string(key: String): String = map[key] as? String
                ?: throw IllegalArgumentException("creation param \"$key\" must be a string")
            return SurfaceParams(
                runtimeId = string("runtimeId"),
                engine = string("engine"),
                moduleName = string("moduleName"),
                initialPropsJson = map["initialPropsJson"] as? String ?: "{}",
                cacheKey = map["cacheKey"] as? String,
            )
        }
    }
}

/**
 * Thread allocation for the plugin.
 *
 * - [main]: Flutter channels, every WebView call and all view attachment.
 *   Android requires WebView methods to run on the thread that created the
 *   WebView, and Flutter requires channel calls on the platform thread.
 * - [bridge]: one ordered background thread for frame validation (size limits,
 *   JSON parsing of props). Being single-threaded preserves message order.
 * - [io]: bundle verification (asset reads, SHA-256).
 *
 * After [shutdown], background submissions are dropped instead of throwing.
 */
internal class EmbedThreads {
    val main = Handler(Looper.getMainLooper())
    private val bridge: ExecutorService = Executors.newSingleThreadExecutor(named("fre-bridge"))
    private val io: ExecutorService = Executors.newFixedThreadPool(2, named("fre-io"))

    @AnyThread
    fun onBridge(task: () -> Unit) = submit(bridge, task)

    @AnyThread
    fun onIo(task: () -> Unit) = submit(io, task)

    @AnyThread
    fun onMain(task: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) task() else main.post(task)
    }

    fun shutdown() {
        bridge.shutdownNow()
        io.shutdownNow()
        main.removeCallbacksAndMessages(null)
    }

    private fun submit(executor: ExecutorService, task: () -> Unit) {
        try {
            executor.execute(task)
        } catch (_: RejectedExecutionException) {
            Log.w(TAG, "Dropped background task after plugin shutdown")
        }
    }

    private fun named(prefix: String): ThreadFactory {
        val counter = AtomicInteger()
        return ThreadFactory { runnable ->
            Thread(runnable, "$prefix-${counter.incrementAndGet()}").apply { isDaemon = true }
        }
    }
}

/** Receives runtime output. Always invoked on the main thread. */
internal interface RuntimeEvents {
    fun onFrame(runtimeId: String, frame: String)
    fun onState(runtimeId: String, state: String)
    fun onError(runtimeId: String, message: String, stack: String?, fatal: Boolean)
}

internal fun utf8Length(value: String): Int {
    var bytes = 0
    var i = 0
    while (i < value.length) {
        val c = value[i]
        bytes += when {
            c.code < 0x80 -> 1
            c.code < 0x800 -> 2
            Character.isHighSurrogate(c) && i + 1 < value.length && Character.isLowSurrogate(value[i + 1]) -> {
                i++
                4
            }
            else -> 3
        }
        i++
    }
    return bytes
}

internal const val TAG = "FlutterReactEmbed"
