group = "dev.flutterreactembed"
version = "1.1.0"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "dev.flutterreactembed"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // WebViewAssetLoader, addWebMessageListener, addDocumentStartJavaScript.
    implementation("androidx.webkit:webkit:1.12.1")
    implementation("androidx.annotation:annotation:1.9.1")
    // React Native engine (New Architecture). compileOnly: apps that use it add
    // react-android and hermes-android themselves; web-only apps ship nothing
    // extra. Built against 0.87; see ReactNativeSupport.
    compileOnly("com.facebook.react:react-android:0.87.1")
}
