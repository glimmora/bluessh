plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.bluessh.bluessh"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.bluessh.bluessh"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // ─────────────────────────────────────────────────────────────────
    //  ABI Splits — generates one APK per architecture.
    //
    //  Each APK contains only the native libraries for that ABI,
    //  dramatically reducing download size for end users.
    //
    //  Output names: app-armeabi-v7a-release.apk, app-arm64-v8a-release.apk,
    //                app-x86-release.apk, app-x86_64-release.apk
    //
    //  Upload all four to Google Play; Play delivers the correct one
    //  automatically based on the device's CPU.
    // ─────────────────────────────────────────────────────────────────
    splits {
        abi {
            isEnable = true

            // Reset the default set and list exactly the four ABIs we build.
            reset()
            include(
                "armeabi-v7a",   // 32-bit ARM  (older / low-end devices)
                "arm64-v8a",     // 64-bit ARM  (most modern phones)
                "x86",           // 32-bit x86  (emulators, Chromebooks)
                "x86_64"         // 64-bit x86  (emulators)
            )

            // true  = one APK per ABI (smaller, used for sideloading / Play)
            // false = universal APK with ALL ABIs (larger, useful for testing)
            isUniversalApk = true

            // The versionCode suffix is appended so each split APK has a
            // unique versionCode required by Google Play:
            //   armeabi-v7a  → original versionCode * 10 + 2
            //   arm64-v8a    → original versionCode * 10 + 4
            //   x86          → original versionCode * 10 + 6
            //   x86_64       → original versionCode * 10 + 8
            //   universal    → original versionCode
        }
    }

    // ─────────────────────────────────────────────────────────────────
    //  versionCodeOverride — gives each split APK a unique versionCode.
    //
    //  Google Play requires every APK in a release to have a different
    //  versionCode.  We multiply the base code by 10 and add a per-ABI
    //  offset so arm64-v8a is always preferred on modern devices.
    // ─────────────────────────────────────────────────────────────────
    applicationVariants.all {
        val variant = this
        variant.outputs
            .map { it as com.android.build.gradle.internal.api.ApkVariantOutputImpl }
            .forEach { output ->
                val abiFilter = output.getFilter(com.android.build.OutputFile.ABI)
                if (abiFilter != null) {
                    val baseCode = flutter.versionCode
                    val suffix = when (abiFilter) {
                        "armeabi-v7a" -> 2
                        "arm64-v8a"   -> 4
                        "x86"         -> 6
                        "x86_64"      -> 8
                        else          -> 0
                    }
                    output.versionCodeOverride = baseCode * 10 + suffix
                }
            }
    }

    // ─────────────────────────────────────────────────────────────────
    //  JNI libs — default location is src/main/jniLibs/ which is where
    //  cargo-ndk places the .so files.  No explicit configuration needed.
    // ─────────────────────────────────────────────────────────────────
}

flutter {
    source = "../.."
}
