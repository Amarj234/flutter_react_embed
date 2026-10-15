package dev.flutterreactembed

import android.content.Context
import android.util.Log
import androidx.annotation.MainThread
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONException
import java.util.UUID

/**
 * Android host for flutter_react_embed.
 *
 * Serves the protocol of `MethodChannelFlutterReactEmbed`:
 *
 * | Channel | Direction | Methods |
 * | --- | --- | --- |
 * | control | Dart -> native | initializeEngine, disposeEngine, updateProps, evictCachedSurface |
 * | messages | Dart -> native | deliver |
 * | messages | native -> Dart | onFrame, onRuntimeState, onRuntimeError |
 *
 * Only the `web` engine is implemented. `react_native` is rejected with
 * `UNSUPPORTED_ENGINE`; it needs a React Native host integration (ReactHost,
 * Hermes, autolinking) in the consuming app, which a plugin cannot provide.
 *
 * One instance exists per FlutterEngine. Everything here runs on the main
 * thread; background work is delegated to [EmbedThreads].
 */
class FlutterReactEmbedPlugin : FlutterPlugin, RuntimeEvents {
    private var control: MethodChannel? = null
    private var messages: MethodChannel? = null
    private var threads: EmbedThreads? = null
    private var binding: FlutterPlugin.FlutterPluginBinding? = null
    private val registry = RuntimeRegistry()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        threads = EmbedThreads()
        control = MethodChannel(binding.binaryMessenger, Protocol.CONTROL_CHANNEL).also {
            it.setMethodCallHandler(::onControlCall)
        }
        messages = MethodChannel(binding.binaryMessenger, Protocol.MESSAGE_CHANNEL).also {
            it.setMethodCallHandler(::onMessageCall)
        }
        binding.platformViewRegistry.registerViewFactory(
            Protocol.VIEW_TYPE_WEB,
            ReactPlatformViewFactory(registry, this),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        control?.setMethodCallHandler(null)
        messages?.setMethodCallHandler(null)
        control = null
        messages = null
        registry.disposeAll()
        threads?.shutdown()
        threads = null
        this.binding = null
    }

    // -------------------------------------------------------------------------
    // Dart -> native
    // -------------------------------------------------------------------------

    @MainThread
    private fun onControlCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initializeEngine" -> initializeEngine(call, SingleReply(result))
            "disposeEngine" -> {
                val runtimeId = call.argument<String>("runtimeId")
                    ?: return result.error(Protocol.E_INVALID_ARGUMENTS, "runtimeId is required", null)
                registry.remove(runtimeId)?.dispose()
                result.success(null)
            }
            "updateProps" -> updateProps(call, SingleReply(result))
            "evictCachedSurface" -> {
                val cacheKey = call.argument<String>("cacheKey")
                    ?: return result.error(Protocol.E_INVALID_ARGUMENTS, "cacheKey is required", null)
                registry.runtimeRetaining(cacheKey)?.evictCached(cacheKey)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    @MainThread
    private fun onMessageCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "deliver") return result.notImplemented()
        val runtimeId = call.argument<String>("runtimeId")
        val frame = call.argument<String>("frame")
        if (runtimeId == null || frame == null) {
            return result.error(Protocol.E_INVALID_ARGUMENTS, "deliver requires runtimeId and frame", null)
        }
        val runtime = registry.runtime(runtimeId)
            ?: return result.error(Protocol.E_UNKNOWN_RUNTIME, "Runtime $runtimeId does not exist", null)
        val reply = SingleReply(result)
        runtime.deliverFromDart(frame) { code, message ->
            if (code == null) reply.success(null) else reply.error(code, message ?: code)
        }
    }

    @MainThread
    private fun initializeEngine(call: MethodCall, reply: SingleReply) {
        val config = try {
            RuntimeConfig.fromArguments(call.arguments)
        } catch (e: IllegalArgumentException) {
            return reply.error(Protocol.E_INVALID_ARGUMENTS, e.message ?: "Invalid config")
        }
        when (config.engine) {
            Protocol.ENGINE_WEB -> Unit
            Protocol.ENGINE_REACT_NATIVE -> return reply.error(
                Protocol.E_UNSUPPORTED_ENGINE,
                "The react_native engine requires a React Native host integration in the app; " +
                    "this build of flutter_react_embed_android provides the web engine only",
            )
            else -> return reply.error(Protocol.E_UNSUPPORTED_ENGINE, "Unknown engine ${config.engine}")
        }

        val pluginBinding = binding ?: return reply.error(Protocol.E_ENGINE_DISPOSED, "Plugin is detached")
        val threads = threads ?: return reply.error(Protocol.E_ENGINE_DISPOSED, "Plugin is detached")
        val appContext: Context = pluginBinding.applicationContext
        val assetDir = pluginBinding.flutterAssets.getAssetFilePathByName(config.bundle.trimEnd('/'))

        // Asset reads and hashing happen off the main thread.
        threads.onIo {
            val check = BundleVerifier.verify(appContext.assets, assetDir, config.bundleSha256)
            threads.onMain {
                if (this.binding == null) {
                    return@onMain reply.error(Protocol.E_ENGINE_DISPOSED, "Plugin detached during boot")
                }
                when (check) {
                    is BundleCheck.NotFound -> reply.error(Protocol.E_BUNDLE_NOT_FOUND, "No ${check.path} in the app's Flutter assets")
                    is BundleCheck.IntegrityMismatch -> reply.error(
                        Protocol.E_BUNDLE_INTEGRITY,
                        "index.html sha256 is ${check.actual}, expected ${check.expected}",
                    )
                    is BundleCheck.Unreadable -> reply.error(Protocol.E_ENGINE_INIT_FAILED, check.reason)
                    BundleCheck.Ok -> boot(config, appContext, assetDir, threads, reply)
                }
            }
        }
    }

    @MainThread
    private fun boot(config: RuntimeConfig, appContext: Context, assetDir: String, threads: EmbedThreads, reply: SingleReply) {
        val runtime = WebRuntime(UUID.randomUUID().toString(), config, appContext, assetDir, threads, this)
        registry.add(runtime)
        runtime.boot { code, message ->
            if (code == null) {
                reply.success(mapOf("runtimeId" to runtime.id))
            } else {
                registry.remove(runtime.id)
                runtime.dispose()
                reply.error(code, message ?: code)
            }
        }
    }

    @MainThread
    private fun updateProps(call: MethodCall, reply: SingleReply) {
        val viewId = call.argument<Int>("viewId")
        val propsJson = call.argument<String>("propsJson")
        if (viewId == null || propsJson == null) {
            return reply.error(Protocol.E_INVALID_ARGUMENTS, "updateProps requires viewId and propsJson")
        }
        val threads = threads ?: return reply.error(Protocol.E_ENGINE_DISPOSED, "Plugin is detached")
        // Props can be large; parse them on the bridge thread.
        threads.onBridge {
            val props = try {
                Protocol.parseObject(propsJson)
            } catch (e: JSONException) {
                return@onBridge threads.onMain { reply.error(Protocol.E_INVALID_ARGUMENTS, "propsJson: ${e.message}") }
            }
            threads.onMain {
                val runtime = registry.runtimeForView(viewId)
                    ?: return@onMain reply.error(Protocol.E_UNKNOWN_VIEW, "No React surface for view $viewId")
                val error = runtime.updateProps(viewId, props)
                if (error == null) reply.success(null) else reply.error(error, "updateProps failed for view $viewId")
            }
        }
    }

    // -------------------------------------------------------------------------
    // native -> Dart (RuntimeEvents, main thread)
    // -------------------------------------------------------------------------

    override fun onFrame(runtimeId: String, frame: String) {
        messages?.invokeMethod("onFrame", mapOf("runtimeId" to runtimeId, "frame" to frame))
    }

    override fun onState(runtimeId: String, state: String) {
        messages?.invokeMethod("onRuntimeState", mapOf("runtimeId" to runtimeId, "state" to state))
    }

    override fun onError(runtimeId: String, message: String, stack: String?, fatal: Boolean) {
        messages?.invokeMethod(
            "onRuntimeError",
            mapOf("runtimeId" to runtimeId, "message" to message, "stack" to stack, "fatal" to fatal),
        )
    }
}

/**
 * Owns live runtimes and the platform-view -> runtime binding. Main thread only.
 */
internal class RuntimeRegistry {
    private val runtimes = LinkedHashMap<String, WebRuntime>()
    private val viewToRuntime = HashMap<Int, String>()

    fun add(runtime: WebRuntime) {
        runtimes[runtime.id] = runtime
    }

    fun runtime(id: String): WebRuntime? = runtimes[id]

    fun remove(id: String): WebRuntime? {
        viewToRuntime.values.removeAll { it == id }
        return runtimes.remove(id)
    }

    fun bindView(viewId: Int, runtimeId: String) {
        viewToRuntime[viewId] = runtimeId
    }

    fun unbindView(viewId: Int) {
        viewToRuntime.remove(viewId)
    }

    fun runtimeForView(viewId: Int): WebRuntime? = viewToRuntime[viewId]?.let(runtimes::get)

    fun runtimeRetaining(cacheKey: String): WebRuntime? = runtimes.values.firstOrNull { it.retainedCacheKey == cacheKey }

    fun disposeAll() {
        val all = runtimes.values.toList()
        runtimes.clear()
        viewToRuntime.clear()
        all.forEach(WebRuntime::dispose)
    }
}

/** Guards a [MethodChannel.Result] against double replies. */
internal class SingleReply(private val result: MethodChannel.Result) {
    private var replied = false

    fun success(value: Any?) {
        if (claim()) result.success(value)
    }

    fun error(code: String, message: String) {
        if (claim()) result.error(code, message, null)
    }

    private fun claim(): Boolean {
        if (replied) {
            Log.w(TAG, "Ignored a second reply to the same method call")
            return false
        }
        replied = true
        return true
    }
}
