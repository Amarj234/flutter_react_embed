package dev.flutterreactembed

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.MutableContextWrapper
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.annotation.MainThread
import com.facebook.react.BaseReactPackage
import com.facebook.react.ReactApplication
import com.facebook.react.ReactHost
import com.facebook.react.ReactInstanceEventListener
import com.facebook.react.ReactPackage
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.WritableNativeArray
import com.facebook.react.bridge.WritableNativeMap
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint
import com.facebook.react.defaults.DefaultReactHost
import com.facebook.react.interfaces.fabric.ReactSurface
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider
import com.facebook.react.runtime.ReactSurfaceImpl
import com.facebook.react.shell.MainReactPackage
import com.facebook.react.soloader.OpenSourceMergedSoMapping
import com.facebook.soloader.SoLoader
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.lang.ref.WeakReference

// Everything in this file references React Native classes. It is only entered
// after ReactNativeSupport.isAvailable returned true.

/**
 * One `react_native` runtime: a logical session on the process-wide
 * [ReactHost] owned by [ReactNativeHostHolder].
 *
 * React Native runs one JavaScript instance per host, so runtimes share it and
 * are told apart by `runtimeId`, which every surface receives in its initial
 * props under [Protocol.RN_META_PROP]. Unlike a WebView document, one runtime
 * can show any number of surfaces at once.
 *
 * ### Threading
 * All state is confined to the main thread. Frames from JS arrive on the
 * native-modules thread and hop through [EmbedThreads.onBridge] (size check)
 * back to main, preserving order.
 *
 * ### Lifecycle
 * - [boot] obtains the host and completes once its ReactContext exists.
 * - [attach] creates a [ReactSurface] over a [MutableContextWrapper] around the
 *   hosting Activity, or reattaches one retained under a cache key.
 * - [detach] removes the surface view and points its context back at the
 *   application, so a retained surface never pins an Activity; without a
 *   cache key the surface is stopped and released.
 * - [dispose] stops every surface and unregisters from [NativeBridgeHub]. The
 *   host itself stays resident (see [ReactNativeHostHolder]).
 *
 * ### JS contract
 * - Root props include `__fre: {runtimeId, viewId, contractVersion, platform, cacheKey}`.
 * - JS -> host: `NativeModules.FlutterReactEmbed.postMessage(runtimeId, frame)`.
 * - host -> JS: `freFrame` events `{runtimeId, frame}` on
 *   `new NativeEventEmitter(NativeModules.FlutterReactEmbed)`.
 * - The first frame JS posts for a runtime is its readiness signal; frames for
 *   JS are queued until it arrives (and again after a JS reload).
 * - Props updates re-render the root natively; no frame is involved.
 */
internal class NativeRuntime(
    override val id: String,
    private val config: RuntimeConfig,
    private val appContext: Context,
    private val bundleAssetPath: String,
    private val threads: EmbedThreads,
    private val events: RuntimeEvents,
) : EmbedRuntime {
    private enum class Phase { CREATED, BOOTING, READY, CRASHED, DISPOSED }

    /** A started surface and the context wrapper its views were inflated with. */
    private class Mounted(
        val surface: ReactSurface,
        val context: MutableContextWrapper,
        val moduleName: String,
        val cacheKey: String?,
    )

    override val engine: String = Protocol.ENGINE_REACT_NATIVE

    private var phase = Phase.CREATED
    private var host: ReactHost? = null
    private val mounted = HashMap<Int, Mounted>()
    private val retained = HashMap<String, Mounted>()
    private val pendingOutbound = ArrayDeque<String>()
    private var jsConnected = false
    private var bootListener: ((code: String?, message: String?) -> Unit)? = null
    private var instanceListener: ReactInstanceEventListener? = null
    private val bootTimeout = Runnable {
        failBoot(Protocol.E_BOOT_TIMEOUT, "React Native did not start within ${Protocol.BOOT_TIMEOUT_MS} ms")
    }

    // -------------------------------------------------------------------------
    // Boot
    // -------------------------------------------------------------------------

    @MainThread
    fun boot(onResult: (code: String?, message: String?) -> Unit) {
        check(phase == Phase.CREATED) { "Runtime $id already booted" }
        phase = Phase.BOOTING
        bootListener = onResult

        val reactHost = try {
            ReactNativeHostHolder.obtain(appContext, bundleAssetPath)
        } catch (e: IllegalStateException) {
            return failBoot(Protocol.E_ENGINE_INIT_FAILED, e.message ?: "React Native host unavailable")
        } catch (e: LinkageError) {
            return failBoot(
                Protocol.E_ENGINE_INIT_FAILED,
                "React Native in this app is binary-incompatible with flutter_react_embed_android " +
                    "(${e.javaClass.simpleName}: ${e.message}); provide the host from your Application " +
                    "by implementing ReactApplication",
            )
        }
        host = reactHost
        NativeBridgeHub.register(this)

        if (reactHost.currentReactContext != null) {
            onHostReady()
            return
        }
        val listener = object : ReactInstanceEventListener {
            override fun onReactContextInitialized(context: ReactContext) {
                threads.onMain { if (phase == Phase.BOOTING) onHostReady() }
            }
        }
        instanceListener = listener
        reactHost.addReactInstanceEventListener(listener)
        threads.main.postDelayed(bootTimeout, Protocol.BOOT_TIMEOUT_MS)
        // Idempotent: concurrent runtimes share one start task.
        reactHost.start()
    }

    @MainThread
    private fun onHostReady() {
        removeInstanceListener()
        threads.main.removeCallbacks(bootTimeout)
        phase = Phase.READY
        bootListener?.invoke(null, null)
        bootListener = null
        events.onState(id, Protocol.STATE_READY)
    }

    // -------------------------------------------------------------------------
    // JS -> Dart (called by NativeBridgeHub on main)
    // -------------------------------------------------------------------------

    @MainThread
    fun receiveFromJs(frame: String) {
        if (phase != Phase.READY) return
        threads.onBridge {
            val bytes = utf8Length(frame)
            threads.onMain {
                when {
                    phase != Phase.READY -> Unit
                    bytes > config.maxMessageBytes -> events.onError(
                        id, "Dropped a $bytes-byte frame from JS (limit ${config.maxMessageBytes})", null, false,
                    )
                    else -> {
                        if (!jsConnected) {
                            // First frame = this runtime's JS bridge is listening.
                            jsConnected = true
                            flushPendingOutbound()
                        }
                        events.onFrame(id, frame)
                    }
                }
            }
        }
    }

    /** The JS instance went away (reload or teardown): re-handshake on the next one. */
    @MainThread
    fun onJsContextLost() {
        jsConnected = false
    }

    /** A fatal JS error reported by the host's exception handler. */
    @MainThread
    fun onFatalJsError(message: String, stack: String?) {
        when (phase) {
            Phase.BOOTING -> failBoot(Protocol.E_ENGINE_INIT_FAILED, "React Native failed to start: $message")
            Phase.READY -> {
                phase = Phase.CRASHED
                pendingOutbound.clear()
                events.onError(id, message, stack, true)
                events.onState(id, Protocol.STATE_CRASHED)
            }
            else -> Unit
        }
    }

    // -------------------------------------------------------------------------
    // Dart -> JS
    // -------------------------------------------------------------------------

    @MainThread
    override fun deliverFromDart(frame: String, onResult: (code: String?, message: String?) -> Unit) {
        threads.onBridge {
            val bytes = utf8Length(frame)
            threads.onMain {
                when {
                    bytes > config.maxMessageBytes ->
                        onResult(Protocol.E_PAYLOAD_TOO_LARGE, "Frame is $bytes bytes; limit is ${config.maxMessageBytes}")
                    phase == Phase.DISPOSED || phase == Phase.CRASHED ->
                        onResult(Protocol.E_ENGINE_DISPOSED, "Runtime $id is ${phase.name.lowercase()}")
                    else -> onResult(postToJs(frame), null)
                }
            }
        }
    }

    /** Returns an error code, or null on success. */
    @MainThread
    private fun postToJs(frame: String): String? {
        if (phase == Phase.READY && jsConnected && NativeBridgeHub.emit(id, frame)) return null
        if (pendingOutbound.size >= Protocol.MAX_PENDING_OUTBOUND) return Protocol.E_QUEUE_FULL
        pendingOutbound.addLast(frame)
        return null
    }

    @MainThread
    private fun flushPendingOutbound() {
        while (pendingOutbound.isNotEmpty()) {
            if (!NativeBridgeHub.emit(id, pendingOutbound.first())) return
            pendingOutbound.removeFirst()
        }
    }

    // -------------------------------------------------------------------------
    // Surfaces
    // -------------------------------------------------------------------------

    @MainThread
    override fun attach(viewId: Int, container: FrameLayout, hostContext: Context, params: SurfaceParams): String? {
        val reactHost = host
        if (phase != Phase.READY || reactHost == null) return "Runtime $id is not available (${phase.name.lowercase()})"
        if (mounted.containsKey(viewId)) return "View $viewId already shows a surface of runtime $id"
        val props = try {
            propsBundle(Protocol.parseObject(params.initialPropsJson), viewId, params.cacheKey)
        } catch (e: JSONException) {
            return "initialPropsJson is not a JSON object: ${e.message}"
        }

        val cacheKey = params.cacheKey
        val reused = cacheKey?.let { key ->
            if (mounted.values.any { it.cacheKey == key }) {
                return "Surface \"$key\" is already on screen; a cached surface can only be shown once"
            }
            retained[key]?.takeIf { it.moduleName == params.moduleName }
        }
        val entry = if (reused != null) {
            retained.remove(cacheKey)
            reused.context.baseContext = hostContext
            // The retained tree still carries the previous viewId and props.
            (reused.surface as? ReactSurfaceImpl)?.updateInitProps(props)
            reused
        } else {
            cacheKey?.let { key -> retained.remove(key)?.let(::release) }
            val wrapper = MutableContextWrapper(hostContext)
            val surface = try {
                reactHost.createSurface(wrapper, params.moduleName, props)
            } catch (e: RuntimeException) {
                return "Could not create surface ${params.moduleName}: ${e.message}"
            }
            surface.start()
            Mounted(surface, wrapper, params.moduleName, cacheKey)
        }

        val view = entry.surface.view ?: run {
            release(entry)
            return "React Native returned no view for ${params.moduleName}"
        }
        (view.parent as? ViewGroup)?.removeView(view)
        container.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        mounted[viewId] = entry
        return null
    }

    @MainThread
    override fun detach(viewId: Int, cacheKey: String?) {
        val entry = mounted.remove(viewId) ?: return
        entry.surface.view?.let { view -> (view.parent as? ViewGroup)?.removeView(view) }
        // Never let a detached surface keep the Activity alive.
        entry.context.baseContext = appContext
        if (cacheKey != null && cacheKey == entry.cacheKey && phase == Phase.READY) {
            retained.put(cacheKey, entry)?.let(::release)
        } else {
            release(entry)
        }
    }

    override fun retains(cacheKey: String): Boolean = retained.containsKey(cacheKey)

    @MainThread
    override fun evictCached(cacheKey: String) {
        retained.remove(cacheKey)?.let(::release)
    }

    @MainThread
    override fun updateProps(viewId: Int, props: JSONObject): String? {
        val entry = mounted[viewId] ?: return Protocol.E_UNKNOWN_VIEW
        val surface = entry.surface as? ReactSurfaceImpl
        if (surface != null) {
            surface.updateInitProps(propsBundle(props, viewId, entry.cacheKey))
            return null
        }
        // Unknown ReactSurface implementation: let the JS bridge apply them.
        return postToJs(Protocol.notification("\$/updateProps", JSONObject().put("viewId", viewId).put("props", props)))
    }

    private fun propsBundle(props: JSONObject, viewId: Int, cacheKey: String?): Bundle {
        val meta = JSONObject()
            .put("runtimeId", id)
            .put("viewId", viewId)
            .put("contractVersion", config.contractVersion)
            .put("platform", "android")
            .put("cacheKey", cacheKey ?: JSONObject.NULL)
        val merged = JSONObject(props.toString()).put(Protocol.RN_META_PROP, meta)
        return Arguments.toBundle(JsonToNative.map(merged)) ?: Bundle()
    }

    // -------------------------------------------------------------------------
    // Teardown
    // -------------------------------------------------------------------------

    @MainThread
    private fun release(entry: Mounted) {
        entry.surface.view?.let { view -> (view.parent as? ViewGroup)?.removeView(view) }
        entry.context.baseContext = appContext
        entry.surface.stop()
        entry.surface.detach()
    }

    @MainThread
    private fun failBoot(code: String, message: String) {
        removeInstanceListener()
        threads.main.removeCallbacks(bootTimeout)
        val listener = bootListener ?: return
        bootListener = null
        phase = Phase.CRASHED
        listener(code, message)
    }

    @MainThread
    private fun removeInstanceListener() {
        val listener = instanceListener ?: return
        instanceListener = null
        host?.removeReactInstanceEventListener(listener)
    }

    @MainThread
    override fun dispose() {
        if (phase == Phase.DISPOSED) return
        failBoot(Protocol.E_ENGINE_DISPOSED, "Runtime $id was disposed during boot")
        phase = Phase.DISPOSED
        removeInstanceListener()
        threads.main.removeCallbacks(bootTimeout)
        pendingOutbound.clear()
        val surfaces = mounted.values.toList() + retained.values.toList()
        mounted.clear()
        retained.clear()
        surfaces.forEach(::release)
        NativeBridgeHub.unregister(this)
        host = null
    }
}

/** Converts Dart-encoded JSON into React Native's native collections. */
private object JsonToNative {
    fun map(json: JSONObject): WritableNativeMap {
        val out = WritableNativeMap()
        val keys = json.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            when (val value = json.get(key)) {
                JSONObject.NULL -> out.putNull(key)
                is Boolean -> out.putBoolean(key, value)
                is Int -> out.putInt(key, value)
                is Number -> out.putDouble(key, value.toDouble())
                is String -> out.putString(key, value)
                is JSONObject -> out.putMap(key, map(value))
                is JSONArray -> out.putArray(key, array(value))
                else -> out.putString(key, value.toString())
            }
        }
        return out
    }

    fun array(json: JSONArray): WritableNativeArray {
        val out = WritableNativeArray()
        for (i in 0 until json.length()) {
            when (val value = json.get(i)) {
                JSONObject.NULL -> out.pushNull()
                is Boolean -> out.pushBoolean(value)
                is Int -> out.pushInt(value)
                is Number -> out.pushDouble(value.toDouble())
                is String -> out.pushString(value)
                is JSONObject -> out.pushMap(map(value))
                is JSONArray -> out.pushArray(array(value))
                else -> out.pushString(value.toString())
            }
        }
        return out
    }
}

/**
 * Lazily created, process-wide [ReactHost]. Main thread only.
 *
 * Resolution order:
 * 1. The app's `Application` implements [ReactApplication] and exposes a
 *    `reactHost`: that host is used as is. The app owns its bundle, package
 *    list and error handling, and must include [FlutterReactEmbedPackage].
 * 2. Otherwise a host is built once with [DefaultReactHost.getDefaultReactHost]
 *    over the Flutter asset [bundleAssetPath] (`index.android.bundle`), the
 *    autolinked `PackageList` when present, and [FlutterReactEmbedPackage].
 *
 * A plugin-built host stays resident for the life of the process.
 * `DefaultReactHost` caches it process-wide, and re-creating Hermes and the
 * bundle costs more than keeping them, so runtimes come and go while the host
 * stays. Activity lifecycle is forwarded so the host never holds a destroyed
 * Activity.
 */
internal object ReactNativeHostHolder {
    private var host: ReactHost? = null
    private var hostBundle: String? = null
    private var ownsHost = false
    private var activity: WeakReference<Activity>? = null
    private var activityResumed = false
    private var architectureLoaded = false
    private val main = Handler(Looper.getMainLooper())

    /** @throws IllegalStateException when no usable host can be provided. */
    @MainThread
    fun obtain(context: Context, bundleAssetPath: String): ReactHost {
        host?.let { existing ->
            check(!ownsHost || hostBundle == bundleAssetPath) {
                "React Native is already running $hostBundle; one process hosts one React Native bundle"
            }
            return existing
        }
        val application = context.applicationContext as? Application
            ?: throw IllegalStateException("No Application context available for React Native")

        val provided = (application as? ReactApplication)?.reactHost
        val created = provided ?: createDefaultHost(application, bundleAssetPath)
        host = created
        hostBundle = bundleAssetPath
        ownsHost = provided == null
        if (provided != null) {
            Log.i(TAG, "Using the ReactHost provided by ${application.javaClass.name}; its own bundle is loaded")
        }
        resumeIfActive(created)
        return created
    }

    private fun createDefaultHost(application: Application, bundleAssetPath: String): ReactHost {
        if (!SoLoader.isInitialized() && !architectureLoaded) {
            // The app did not call loadReactNative() itself. Prefer the entry
            // point the React Native Gradle plugin generates for this app (it
            // also honours the app's BuildConfig flags); otherwise bootstrap
            // what it would.
            architectureLoaded = true
            try {
                Class.forName("com.facebook.react.ReactNativeApplicationEntryPoint")
                    .getMethod("loadReactNative", Context::class.java)
                    .invoke(null, application)
            } catch (_: ReflectiveOperationException) {
                SoLoader.init(application, OpenSourceMergedSoMapping)
                DefaultNewArchitectureEntryPoint.load()
            }
        }
        return DefaultReactHost.getDefaultReactHost(
            context = application,
            packageList = packagesFor(application),
            jsMainModulePath = "index",
            jsBundleAssetPath = bundleAssetPath,
            jsBundleFilePath = null,
            jsRuntimeFactory = null,
            useDevSupport = false,
            cxxReactPackageProviders = emptyList(),
            exceptionHandler = { error -> main.post { NativeBridgeHub.reportFatal(error) } },
            bindingsInstaller = null,
        )
    }

    /** The app's autolinked packages (or the core package) plus the bridge package. */
    private fun packagesFor(application: Application): List<ReactPackage> {
        val packages = ArrayList<ReactPackage>()
        try {
            val packageList = Class.forName("com.facebook.react.PackageList")
            val instance = packageList.getConstructor(Application::class.java).newInstance(application)
            @Suppress("UNCHECKED_CAST")
            packages += packageList.getMethod("getPackages").invoke(instance) as List<ReactPackage>
        } catch (_: ReflectiveOperationException) {
            // No React Native Gradle plugin autolinking in this app.
            packages += MainReactPackage()
        }
        if (packages.none { it is FlutterReactEmbedPackage }) {
            packages += FlutterReactEmbedPackage()
        }
        return packages
    }

    @MainThread
    fun onActivityResumed(activity: Activity) {
        this.activity = WeakReference(activity)
        activityResumed = true
        host?.onHostResume(activity)
    }

    @MainThread
    fun onActivityPaused(activity: Activity) {
        if (this.activity?.get() !== activity) return
        activityResumed = false
        host?.onHostPause(activity)
    }

    @MainThread
    fun onActivityDestroyed(activity: Activity) {
        if (this.activity?.get() !== activity) return
        activityResumed = false
        this.activity = null
        // Releases the host's reference to the Activity; the JS instance stays.
        host?.onHostDestroy(activity)
    }

    private fun resumeIfActive(reactHost: ReactHost) {
        val current = activity?.get()
        if (current != null && activityResumed) reactHost.onHostResume(current)
    }
}

/**
 * Routes frames between [NativeRuntime]s and the JS instance's
 * [FlutterReactEmbedModule]. Main thread only, except [fromJs].
 */
internal object NativeBridgeHub {
    private val runtimes = HashMap<String, NativeRuntime>()
    private var module: WeakReference<FlutterReactEmbedModule>? = null
    private val main = Handler(Looper.getMainLooper())

    @MainThread
    fun register(runtime: NativeRuntime) {
        runtimes[runtime.id] = runtime
    }

    @MainThread
    fun unregister(runtime: NativeRuntime) {
        runtimes.remove(runtime.id)
    }

    /** Sends [frame] to JS. Returns false when no JS instance is listening. */
    @MainThread
    fun emit(runtimeId: String, frame: String): Boolean {
        val target = module?.get() ?: return false
        return target.emit(runtimeId, frame)
    }

    /** Called on the native-modules thread. */
    fun fromJs(runtimeId: String, frame: String) {
        main.post { runtimes[runtimeId]?.receiveFromJs(frame) }
    }

    fun moduleCreated(created: FlutterReactEmbedModule) {
        main.post { module = WeakReference(created) }
    }

    fun moduleInvalidated(invalidated: FlutterReactEmbedModule) {
        main.post {
            if (module?.get() === invalidated) module = null
            runtimes.values.toList().forEach(NativeRuntime::onJsContextLost)
        }
    }

    @MainThread
    fun reportFatal(error: Exception) {
        val message = error.message ?: error.javaClass.simpleName
        val stack = Log.getStackTraceString(error)
        runtimes.values.toList().forEach { it.onFatalJsError(message, stack) }
    }
}

/**
 * Registers [FlutterReactEmbedModule]. Add it to your `ReactApplication`'s
 * package list when your app provides its own `ReactHost`; the plugin adds it
 * automatically to the host it creates.
 */
class FlutterReactEmbedPackage : BaseReactPackage() {
    override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
        if (name == Protocol.RN_MODULE) FlutterReactEmbedModule(reactContext) else null

    override fun getReactModuleInfoProvider(): ReactModuleInfoProvider = ReactModuleInfoProvider {
        mapOf(
            Protocol.RN_MODULE to ReactModuleInfo(
                name = Protocol.RN_MODULE,
                className = FlutterReactEmbedModule::class.java.name,
                canOverrideExistingModule = false,
                needsEagerInit = false,
                isCxxModule = false,
                isTurboModule = false,
            ),
        )
    }
}

/**
 * `NativeModules.FlutterReactEmbed`: the JS side of the frame transport.
 * Runs through React Native's legacy-module interop layer, so it needs no
 * codegen spec in the app.
 */
class FlutterReactEmbedModule(context: ReactApplicationContext) : ReactContextBaseJavaModule(context) {
    override fun getName(): String = Protocol.RN_MODULE

    override fun initialize() {
        super.initialize()
        NativeBridgeHub.moduleCreated(this)
    }

    override fun invalidate() {
        NativeBridgeHub.moduleInvalidated(this)
        super.invalidate()
    }

    @ReactMethod
    fun postMessage(runtimeId: String, frame: String) {
        NativeBridgeHub.fromJs(runtimeId, frame)
    }

    /** Required by `NativeEventEmitter`. */
    @ReactMethod
    fun addListener(@Suppress("UNUSED_PARAMETER") eventName: String) = Unit

    /** Required by `NativeEventEmitter`. */
    @ReactMethod
    fun removeListeners(@Suppress("UNUSED_PARAMETER") count: Double) = Unit

    internal fun emit(runtimeId: String, frame: String): Boolean {
        val context = reactApplicationContext
        if (!context.hasActiveReactInstance()) return false
        val payload = Arguments.createMap()
        payload.putString("runtimeId", runtimeId)
        payload.putString("frame", frame)
        context.emitDeviceEvent(Protocol.RN_FRAME_EVENT, payload)
        return true
    }
}
