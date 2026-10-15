pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")

// React Native engine (opt-in): FRE_REACT_NATIVE=1, set by tool/run_local_test.sh
// after it installs the probe app into ../.rn_mock. Without it the example is
// web-only and needs no node_modules.
//
// What the React Native settings plugin (com.facebook.react.settings) would do,
// done here because a `plugins {}` entry cannot be conditional:
// 1. include the React Native Gradle plugin build, so the root project can put
//    com.facebook.react on its classpath (see ../build.gradle.kts);
// 2. write the CLI's autolinking config where the app plugin reads it, which in
//    a Flutter app is the redirected root build directory (example/build), not
//    android/build where the settings plugin would write it;
// 3. include every autolinked library that has Android sources.
if (System.getenv("FRE_REACT_NATIVE") == "1") {
    val reactNativeRoot = file("../.rn_mock")
    require(reactNativeRoot.resolve("node_modules/react-native").isDirectory) {
        "FRE_REACT_NATIVE=1 needs the React Native probe installed: run tool/run_local_test.sh bundle"
    }
    includeBuild(reactNativeRoot.resolve("node_modules/@react-native/gradle-plugin"))

    val autolinkingConfig =
        providers
            .exec {
                commandLine("npx", "@react-native-community/cli", "config")
                workingDir = reactNativeRoot
            }.standardOutput.asText
            .get()
    val autolinkingFile = file("../build/generated/autolinking/autolinking.json")
    autolinkingFile.parentFile.mkdirs()
    autolinkingFile.writeText(autolinkingConfig)

    @Suppress("UNCHECKED_CAST")
    val dependencies =
        (groovy.json.JsonSlurper().parseText(autolinkingConfig) as Map<String, Any?>)["dependencies"]
            as Map<String, Map<String, Any?>>? ?: emptyMap()
    for ((name, dependency) in dependencies) {
        @Suppress("UNCHECKED_CAST")
        val android = (dependency["platforms"] as Map<String, Any?>?)?.get("android") as Map<String, Any?>?
        val sourceDir = android?.get("sourceDir") as String? ?: continue
        if (android["isPureCxxDependency"] == true) continue
        // Same project naming as the settings plugin (nameCleansed).
        val path = ":" + name.replace(Regex("[~*!'()]+"), "_").replace(Regex("^@([\\w-.]+)/"), "$1_")
        include(path)
        project(path).projectDir = file(sourceDir)
    }
}
