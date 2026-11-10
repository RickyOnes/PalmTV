# JNI：native 方法所在类不能被混淆/裁剪（符号名按 Java_com_rickyone_palmtv_... 约定）
-keepclasseswithmembernames class * {
    native <methods>;
}
-keep class com.rickyone.palmtv.native.** { *; }
-keep class com.rickyone.palmtv.data.** { *; }
