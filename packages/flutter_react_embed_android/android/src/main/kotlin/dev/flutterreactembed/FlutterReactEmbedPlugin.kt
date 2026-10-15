package dev.flutterreactembed

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.util.Log
import androidx.annotation.MainThread
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
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
 * Engines:
 *
 * - `web`: [WebRuntime], always available.
 * - `react_native`: NativeRuntime on a shared `ReactHost`. React Native is a
 *   `compileOnly` dependency; when the app does not ship it, the engine is
 *   rejected with `UNSUPPORTED_ENGINE` and no React Native class is loaded.
 *
 * One instance exists per FlutterEngine. Everything here runs on the main
 * thread; background work is delegated to [EmbedThreads]. As [ActivityAware]
 * the plugin forwards the hosting Activity's resume, pause and destroy to the
 * React Native host, so it never keeps a destroyed Activity.
 */
class FlutterReactEmbedPlugin : FlutterPlugin, ActivityAware, RuntimeEvents {
    private var control: MethodChannel? = null
    private var messages: MethodChannel? = null
    private var threads: EmbedThreads? = null
    private var binding: FlutterPlugin.FlutterPluginBinding? = null
    private val registry = RuntimeRegistry()
    private var activityBinding: ActivityPluginBinding? = null
    private var lifecycleCallbacks: Application.ActivityLifecycleCallbacks? = null

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
            ReactPlatformViewFactory(Protocol.ENGINE_WEB, registry, this),
        )
        binding.platformViewRegistry.registerViewFactory(
            Protocol.VIEW_TYPE_REACT_NATIVE,
            ReactPlatformViewFactory(Protocol.ENGINE_REACT_NATIVE, registry, this),
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
    // Activity lifecycle (forwarded to the React Native host)
    // -------------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    @MainThread
    private fun attachActivity(binding: ActivityPluginBinding) {
        detachActivity()
        activityBinding = binding
        val activity = binding.activity
        val callbacks = ActivityLifecycleForwarder(activity)
        activity.application.registerActivityLifecycleCallbacks(callbacks)
        lifecycleCallbacks = callbacks
        // Attachment happens after onCreate; a resumed Activity will not call back.
        ReactNativeSupport.onActivityResumed(activity)
    }

    @MainThread
    private fun detachActivity() {
        val binding = activityBinding ?: return
        activityBinding = null
        val activity = binding.activity
        lifecycleCallbacks?.let(activity.application::unregisterActivityLifecycleCallbacks)
        lifecycleCallbacks = null
        // The Activity is going away or being recreated: release it everywhere.
        ReactNativeSupport.onActivityPaused(activity)
        ReactNativeSupport.onActivityDestroyed(activity)
    }

    /** Forwards one Activity's resume and pause; ignores every other Activity. */
    private class ActivityLifecycleForwarder(activity: Activity) : Application.ActivityLifecycleCallbacks {
        private val target = java.lang.ref.WeakReference(activity)

        override fun onActivityResumed(activity: Activity) {
            if (activity === target.get()) ReactNativeSupport.onActivityResumed(activity)
        }

        override fun onActivityPaused(activity: Activity) {
            if (activity === target.get()) ReactNativeSupport.onActivityPaused(activity)
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
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
                registry.runtimesRetaining(cacheKey).forEach { it.evictCached(cacheKey) }
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
            Protocol.ENGINE_WEB, Protocol.ENGINE_REACT_NATIVE -> Unit
            else -> return reply.error(Protocol.E_UNSUPPORTED_ENGINE, "Unknown engine ${config.engine}")
        }
        val isNative = config.engine == Protocol.ENGINE_REACT_NATIVE

        val pluginBinding = binding ?: return reply.error(Protocol.E_ENGINE_DISPOSED, "Plugin is detached")
        val threads = threads ?: return reply.error(Protocol.E_ENGINE_DISPOSED, "Plugin is detached")
        val appContext: Context = pluginBinding.applicationContext
        if (isNative) {
            ReactNativeSupport.missingRequirement(appContext)?.let { reason ->
                return reply.error(Protocol.E_UNSUPPORTED_ENGINE, reason)
            }
        }
        // `web`: the SPA directory. `react_native`: the index.android.bundle file.
        val assetPath = pluginBinding.flutterAssets.getAssetFilePathByName(config.bundle.trimEnd('/'))

        // Asset reads and hashing happen off the main thread.
        threads.onIo {
            val check = if (isNative) {
                BundleVerifier.verifyFile(appContext.assets, assetPath, config.bundleSha256)
            } else {
                BundleVerifier.verify(appContext.assets, assetPath, config.bundleSha256)
            }
            threads.onMain {
                if (this.binding == null) {
                    return@onMain reply.error(Protocol.E_ENGINE_DISPOSED, "Plugin detached during boot")
                }
                when (check) {
                    is BundleCheck.NotFound -> reply.error(Protocol.E_BUNDLE_NOT_FOUND, "No ${check.path} in the app's Flutter assets")
                    is BundleCheck.IntegrityMismatch -> reply.error(
                        Protocol.E_BUNDLE_INTEGRITY,
                        "${if (isNative) config.bundle else "index.html"} sha256 is ${check.actual}, expected ${check.expected}",
                    )
                    is BundleCheck.Unreadable -> reply.error(Protocol.E_ENGINE_INIT_FAILED, check.reason)
                    BundleCheck.Ok ->
                        if (isNative) bootNative(config, appContext, assetPath, threads, reply)
                        else boot(config, appContext, assetPath, threads, reply)
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

    /** Kept apart from [boot] so NativeRuntime is only resolved when React Native is linked. */
    @MainThread
    private fun bootNative(config: RuntimeConfig, appContext: Context, bundlePath: String, threads: EmbedThreads, reply: SingleReply) {
        val runtime = NativeRuntime(UUID.randomUUID().toString(), config, appContext, bundlePath, threads, this)
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
    private val runtimes = LinkedHashMap<String, EmbedRuntime>()
    private val viewToRuntime = HashMap<Int, String>()

    fun add(runtime: EmbedRuntime) {
        runtimes[runtime.id] = runtime
    }

    fun runtime(id: String): EmbedRuntime? = runtimes[id]

    fun remove(id: String): EmbedRuntime? {
        viewToRuntime.values.removeAll { it == id }
        return runtimes.remove(id)
    }

    fun bindView(viewId: Int, runtimeId: String) {
        viewToRuntime[viewId] = runtimeId
    }

    fun unbindView(viewId: Int) {
        viewToRuntime.remove(viewId)
    }

    fun runtimeForView(viewId: Int): EmbedRuntime? = viewToRuntime[viewId]?.let(runtimes::get)

    fun runtimesRetaining(cacheKey: String): List<EmbedRuntime> = runtimes.values.filter { it.retains(cacheKey) }

    fun disposeAll() {
        val all = runtimes.values.toList()
        runtimes.clear()
        viewToRuntime.clear()
        all.forEach(EmbedRuntime::dispose)
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
