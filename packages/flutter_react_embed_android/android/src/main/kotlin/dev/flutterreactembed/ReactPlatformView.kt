package dev.flutterreactembed

import android.content.Context
import android.util.Log
import android.view.View
import android.widget.FrameLayout
import androidx.annotation.MainThread
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** Creates [ReactPlatformView]s for `dev.flutter_react_embed/view/web`. */
internal class ReactPlatformViewFactory(
    private val registry: RuntimeRegistry,
    private val events: RuntimeEvents,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    @MainThread
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        ReactPlatformView(context, viewId, args, registry, events)
}

/**
 * Flutter-side handle for one embedded React surface.
 *
 * The view is a plain [FrameLayout] container; the runtime's WebView is moved
 * into it on creation and out of it on [dispose]. Creation never throws:
 * Flutter cannot surface a factory exception to Dart, so failures leave an
 * empty container and are reported through `onRuntimeError` (non-fatal), which
 * `ReactView` turns into its error state when relevant.
 */
internal class ReactPlatformView(
    context: Context,
    private val viewId: Int,
    args: Any?,
    private val registry: RuntimeRegistry,
    events: RuntimeEvents,
) : PlatformView {

    private var container: FrameLayout? = FrameLayout(context)
    private var runtime: WebRuntime? = null
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

    /** Attaches the runtime's WebView. Returns an error message, or null. */
    @MainThread
    private fun mount(context: Context, params: SurfaceParams): String? {
        if (params.engine != Protocol.ENGINE_WEB) {
            return "Engine ${params.engine} is not supported by this view type"
        }
        val target = registry.runtime(params.runtimeId)
            ?: return "Runtime ${params.runtimeId} does not exist or was disposed"
        val host = container ?: return "Platform view $viewId was already disposed"
        target.attach(viewId, host, context, params)?.let { return it }
        runtime = target
        registry.bindView(viewId, target.id)
        return null
    }

    override fun getView(): View? = container

    /**
     * Called by Flutter when the platform view is removed. Detaches the
     * WebView (handing the runtime back to the application context) and drops
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
