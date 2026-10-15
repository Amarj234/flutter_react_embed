package dev.flutterreactembed

import android.content.Context
import android.util.Log
import android.view.View
import android.widget.FrameLayout
import androidx.annotation.MainThread
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Creates [ReactPlatformView]s. One instance is registered per view type:
 * `dev.flutter_react_embed/view/web` ([Protocol.ENGINE_WEB]) and
 * `dev.flutter_react_embed/view/react_native` ([Protocol.ENGINE_REACT_NATIVE]).
 */
internal class ReactPlatformViewFactory(
    private val engine: String,
    private val registry: RuntimeRegistry,
    private val events: RuntimeEvents,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    @MainThread
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        ReactPlatformView(context, viewId, args, engine, registry, events)
}

/**
 * Flutter-side handle for one embedded React surface.
 *
 * The view is a plain [FrameLayout] container that switches on the engine:
 *
 * - `web`: the runtime's WebView is moved in on creation and out on [dispose].
 * - `react_native`: a `ReactSurface` view is created (or a retained one
 *   reattached) on creation and removed on [dispose].
 *
 * Both go through [EmbedRuntime.attach]/[EmbedRuntime.detach], which swap the
 * runtime's context between the hosting Activity and the application, so no
 * Activity outlives its view. Creation never throws: Flutter cannot surface a
 * factory exception to Dart, so failures leave an empty container and are
 * reported through `onRuntimeError` (non-fatal), which `ReactView` turns into
 * its error state when relevant.
 */
internal class ReactPlatformView(
    context: Context,
    private val viewId: Int,
    args: Any?,
    private val viewEngine: String,
    private val registry: RuntimeRegistry,
    events: RuntimeEvents,
) : PlatformView {

    private var container: FrameLayout? = FrameLayout(context)
    private var runtime: EmbedRuntime? = null
    private var cacheKey: String? = null

    init {
        val params = try {
            SurfaceParams.fromArguments(args)
        } catch (e: IllegalArgumentException) {
            Log.e(TAG, "Platform view $viewId: ${e.message}")
            null
        }
        if (params != null) {
            cacheKey = params.cacheKey
            mount(context, params)?.let { error ->
                Log.e(TAG, "Platform view $viewId: $error")
                events.onError(params.runtimeId, error, null, false)
            }
        }
    }

    /** Attaches the runtime's surface. Returns an error message, or null. */
    @MainThread
    private fun mount(context: Context, params: SurfaceParams): String? {
        if (params.engine != viewEngine) {
            return "Engine ${params.engine} is not supported by the $viewEngine view type"
        }
        val target = registry.runtime(params.runtimeId)
            ?: return "Runtime ${params.runtimeId} does not exist or was disposed"
        if (target.engine != params.engine) {
            return "Runtime ${params.runtimeId} runs ${target.engine}, not ${params.engine}"
        }
        val host = container ?: return "Platform view $viewId was already disposed"
        target.attach(viewId, host, context, params)?.let { return it }
        runtime = target
        registry.bindView(viewId, target.id)
        return null
    }

    override fun getView(): View? = container

    /**
     * Called by Flutter when the platform view is removed. Detaches the
     * surface (handing the runtime back to the application context) and drops
     * every reference this view holds, so neither the container nor the
     * Activity context it was created with outlive it.
     */
    @MainThread
    override fun dispose() {
        runtime?.detach(viewId, cacheKey)
        registry.unbindView(viewId)
        container?.removeAllViews()
        container = null
        runtime = null
    }
}
