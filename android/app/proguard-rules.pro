# Keep the Flutter engine + plugin registrant.
#
# Scoped per package instead of a blanket io.flutter.** keep: the engine's
# embedding and engine packages are reached reflectively from libflutter.so
# via JNI name resolution, so they must survive R8 unchanged. A blanket wild
# card kept every Flutter class, making the narrower rules below dead weight.
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.engine.** { *; }
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.plugins.** { *; }

# just_audio -> androidx.media3 (ExoPlayer). media3 ships consumer rules, but
# keep it explicitly to be safe under aggressive optimization.
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# audio_service -> MediaSession / MediaBrowser glue.
-keep class com.ryanheise.audioservice.** { *; }
-keep class android.support.v4.media.** { *; }
-keep class androidx.media.** { *; }

# Generic JNI native methods.
-keepclasseswithmembernames class * {
    native <methods>;
}

# Flutter Play Core split install fallback
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
