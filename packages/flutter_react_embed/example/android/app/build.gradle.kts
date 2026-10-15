plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.flutterreactembed.flutter_react_embed_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.flutterreactembed.flutter_react_embed_example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// React Native engine for local hybrid tests. Off unless tool/run_local_test.sh
// (or you) sets FRE_REACT_NATIVE=1, so the default example stays web-only.
//
// This is the React Native Gradle plugin's regular app setup. It pins
// react-android and hermes-android to the installed react-native package, runs
// codegen, and builds libappmodules.so (which
// registers React Native's core modules) plus PackageList. It is applied
// imperatively because a `plugins {}` entry cannot be conditional, and
// configured without its types for the same reason.
if (System.getenv("FRE_REACT_NATIVE") == "1") {
    apply(plugin = "com.facebook.react")
    val reactNativeRoot = rootProject.file("../.rn_mock")
    val react = extensions.getByName("react")
    fun <T : Any> reactProperty(name: String): T {
        @Suppress("UNCHECKED_CAST")
        return react.withGroovyBuilder { getProperty(name) } as T
    }
    reactProperty<DirectoryProperty>("root").set(reactNativeRoot)
    reactProperty<DirectoryProperty>("reactNativeDir").set(reactNativeRoot.resolve("node_modules/react-native"))
    reactProperty<DirectoryProperty>("codegenDir").set(reactNativeRoot.resolve("node_modules/@react-native/codegen"))
    reactProperty<RegularFileProperty>("cliFile").set(reactNativeRoot.resolve("node_modules/react-native/cli.js"))
    // The bundle ships as a Flutter asset (assets/rn/), so React Native's own
    // bundling task never runs, in any variant.
    reactProperty<ListProperty<String>>("debuggableVariants").set(listOf("debug", "profile", "release"))
    react.withGroovyBuilder { "autolinkLibrariesWithApp"() }

    // Versionless, as in React Native's app template: the plugin pins them to
    // the installed react-native and substitutes Hermes' Maven group.
    dependencies {
        "implementation"("com.facebook.react:react-android")
        "implementation"("com.facebook.react:hermes-android")
    }
}
