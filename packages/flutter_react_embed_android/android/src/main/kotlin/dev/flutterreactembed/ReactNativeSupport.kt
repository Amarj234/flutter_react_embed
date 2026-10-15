package dev.flutterreactembed

import android.app.Activity
import android.content.Context
import dalvik.system.BaseDexClassLoader

/**
 * Detects React Native on the app's classpath without referencing any of its
 * classes.
 *
 * `react-android` is a `compileOnly` dependency of this plugin, so web-only
 * apps never ship it. Every code path that touches React Native classes
 * (NativeRuntime.kt) is entered only after [isAvailable] returned true;
 * otherwise ART would fail to resolve them at call time.
 */
internal object ReactNativeSupport {
    val isAvailable: Boolean by lazy {
        try {
            Class.forName("com.facebook.react.ReactHost", false, ReactNativeSupport::class.java.classLoader)
            Class.forName("com.facebook.react.defaults.DefaultReactHost", false, ReactNativeSupport::class.java.classLoader)
            true
        } catch (_: ClassNotFoundException) {
            false
        } catch (_: LinkageError) {
            false
        }
    }

    const val UNAVAILABLE_MESSAGE =
        "The react_native engine needs React Native in the host app: apply the React Native " +
            "Gradle plugin (com.facebook.react) with autolinking to the Android app " +
            "(see the flutter_react_embed README, \"React Native engine\")"

    const val APPMODULES_MESSAGE =
        "React Native is on the classpath but libappmodules.so is missing, so its core modules " +
            "(PlatformConstants, ExceptionsManager, ...) cannot be registered and every bundle would " +
            "crash on load. Apply the React Native Gradle plugin (com.facebook.react) with " +
            "autolinkLibrariesWithApp() to the Android app; adding react-android alone is not enough " +
            "(see the flutter_react_embed README, \"React Native engine\")"

    /**
     * Returns why the `react_native` engine cannot start in this app, or null.
     *
     * Besides the classes, React Native's New Architecture needs the app's
     * `libappmodules.so`, built by the React Native Gradle plugin from codegen
     * output: its JNI_OnLoad installs the provider that binds Java TurboModules,
     * core ones included. Without it, the bundle's first `TurboModuleRegistry`
     * lookup throws and the host destroys and recreates its instance in a loop.
     */
    fun missingRequirement(context: Context): String? {
        if (!isAvailable) return UNAVAILABLE_MESSAGE
        val loader = context.classLoader as? BaseDexClassLoader ?: return null
        return if (loader.findLibrary("appmodules") == null) APPMODULES_MESSAGE else null
    }

    /** Forwards Activity lifecycle to the React Native host, if one was created. */
    fun onActivityResumed(activity: Activity) {
        if (isAvailable) ReactNativeHostHolder.onActivityResumed(activity)
    }

    fun onActivityPaused(activity: Activity) {
        if (isAvailable) ReactNativeHostHolder.onActivityPaused(activity)
    }

    fun onActivityDestroyed(activity: Activity) {
        if (isAvailable) ReactNativeHostHolder.onActivityDestroyed(activity)
    }
}
