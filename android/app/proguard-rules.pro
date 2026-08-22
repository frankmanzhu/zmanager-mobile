# The UniFFI-generated bridge (org.tzap.zmanager.mobile.bridge.generated)
# subclasses com.sun.jna.Structure and implements com.sun.jna.Library /
# com.sun.jna.Callback. JNA maps native struct layout and native function
# calls to these types by reflecting on field order (@Structure.FieldOrder)
# and method/field names at runtime, so R8 must not rename, remove, or inline
# any of it. The JNA jar (net.java.dev.jna:jna) ships no consumer ProGuard
# rules of its own, so these keeps are required, not defensive duplication.
-keep class org.tzap.zmanager.mobile.bridge.generated.** { *; }
-keepclassmembers class org.tzap.zmanager.mobile.bridge.generated.** { *; }

-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.Structure { *; }
-keep interface * extends com.sun.jna.Library { *; }
-keep interface * extends com.sun.jna.Callback { *; }
-dontwarn com.sun.jna.**

# @Structure.FieldOrder is read reflectively at runtime; annotation
# attributes are stripped by R8 by default.
-keepattributes *Annotation*
