# ═══════════════════════════════════════════════════════════════
#  BlueSSH ProGuard / R8 Rules
# ═══════════════════════════════════════════════════════════════

# ── JNI Bridge Classes (MUST NOT be obfuscated) ──────────────
-keep class com.bluessh.bluessh.EngineBridge { *; }
-keep class com.bluessh.bluessh.SessionForegroundService { *; }
-keep class com.bluessh.bluessh.MainActivity { *; }

# Keep native method signatures from being obfuscated
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep the Rust engine JNI exports
-keepclasseswithmembernames class com.bluessh.bluessh.EngineBridge {
    native <methods>;
}

# ── Flutter Embedding ────────────────────────────────────────
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# ── permission_handler ───────────────────────────────────────
-keep class com.baseflow.permissionhandler.** { *; }

# ── flutter_secure_storage ───────────────────────────────────
-keep class com.it_nomades.fluttersecurestorage.** { *; }

# ── file_picker ──────────────────────────────────────────────
-keep class com.mr.flutter.plugin.filepicker.** { *; }

# ── shared_preferences ───────────────────────────────────────
-keep class io.flutter.plugins.sharedpreferences.** { *; }

# ── path_provider ────────────────────────────────────────────
-keep class io.flutter.plugins.pathprovider.** { *; }

# ── General Rules ────────────────────────────────────────────
# Keep enums used in serialization
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Keep Parcelable implementations
-keep class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator *;
}

# Keep Serializable implementations
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# Suppress warnings for optional dependencies
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**
-dontwarn com.google.android.play.core.**

# Flutter Play Store split/deferred components — optional at runtime
-keep class io.flutter.embedding.engine.deferredcomponents.** { *; }
-keep class io.flutter.embedding.android.FlutterPlayStoreSplitApplication { *; }

# Flutter Play Store split/deferred components — optional at runtime
-keep class io.flutter.embedding.engine.deferredcomponents.** { *; }
-keep class io.flutter.embedding.android.FlutterPlayStoreSplitApplication { *; }
-dontwarn com.google.android.play.core.**

# Keep attributes for debugging
-keepattributes SourceFile,LineNumberTable
