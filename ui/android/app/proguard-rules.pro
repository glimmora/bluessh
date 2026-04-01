# Keep the JNI bridge class and all its native methods
-keep class com.bluessh.bluessh.EngineBridge { *; }
-keep class com.bluessh.bluessh.SessionForegroundService { *; }

# Keep native method signatures from being obfuscated
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep the Rust engine JNI exports
-keepclasseswithmembernames class com.bluessh.bluessh.EngineBridge {
    native <methods>;
}
