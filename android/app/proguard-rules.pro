# R8 混淆规则 —— **播放内核的 JNI 契约**
#
# ## 为什么必须有这个文件（真实崩溃，不是预防性措施）
#
# release 包实测崩溃（`flutter build apk --release`）：
# ```
# E/CineFlowMPV: onMethodCall initialize 失败
# E/CineFlowMPV: java.lang.NoSuchMethodError: no static method
#     "Lcom/cineflow/app/player/MPVLib;.onEvent(Ljava/lang/String;)V"
#     at com.cineflow.app.player.MPVLib.nativeCreate(Native Method)
# ```
# 后果：**视频完全无法播放**（`initialize` 失败 → 内核起不来）。
# 现象是黑屏 / 无法播放，**debug 包完全正常**（debug 不混淆）。
#
# ## 根因
# Flutter 的 release 构建**默认开启 R8**（`minifyEnabled`）。
# R8 从"Java 侧有无调用点"判断死代码：
#   · `MPVLib.onEvent(json)` 由 **C 代码**通过 `GetStaticMethodID` 按**名字**回调
#     （见 `app/src/main/cpp/cineflow_mpv.c:393`），
#     Java 侧**一个调用点都没有** → R8 判定"没人用" → 删除或改名
#   · `external fun nativeXxx` 同理：`native` 方法靠名字与 C 符号绑定
#
# **这是 R8 的正确行为** —— 它不知道 native 侧有引用。
# 唯一的解法是把契约显式声明给 R8。
#
# ## ⚠️ 与官方 proguard-android-optimize.txt 的关系
# Flutter 会自动带上 AGP 默认的 `proguard-android-optimize.txt`
# （其中已保留 `native <methods>` 的**名字**），但那**不覆盖**：
#   · 被 native **回调**的普通方法（如 `onEvent`）—— 它不含 `native` 关键字
#   · 持有 `external fun` 的类本身（类名也可能是 `FindClass` 的目标）
# 所以这些规则必须我们自己写。
#
# ## 改这个文件后必须验证
# **只有 release 包能暴露问题**（debug 不混淆）。
# 验收：`flutter build apk --release` → 装机 → **真机起播成功**
# 且 logcat 出现 `mpv 已就绪`（而非 `initialize 失败`）。

# ---------------------------------------------------------------------------
# 1. MPVLib：JNI 双向契约的宿主
# ---------------------------------------------------------------------------
# 向上（Dart → Kotlin）：无影响（那是 Dart 侧按字符串找通道，R8 不动 Dart）
# 向下（C ↔ Kotlin）：**两个方向都按名字**，故整个类都不能动
-keep class com.cineflow.app.player.MPVLib { *; }

# 保险：即便将来把 JNI 桥拆到别的类，凡带 native 方法的类都别动
-keepclasseswithmembernames class * {
    native <methods>;
}

# 被 native 代码**回调**的方法（C 侧 GetStaticMethodID 按名字查）。
# `onEvent` 是当前唯一一个；将来若 C 侧新增回调，**必须同步加到这里**。
-keepclassmembers class com.cineflow.app.player.MPVLib {
    public static void onEvent(java.lang.String);
}

# ---------------------------------------------------------------------------
# 2. 其余原生通道（与 JNI 同理：名字即契约）
# ---------------------------------------------------------------------------
# 这三处是 Flutter 的 MethodChannel（按**字符串**匹配方法名），
# 严格说 R8 不影响它们（字符串常量不会被混淆）。
# 但 handler 所在的类若整体被删，通道就断了 —— 而它们只被 MainActivity 注册，
# 若将来注册方式变化可能成为"无人引用"。
# 用 -keep 兜住，代价是几百字节，收益是"release 不会静默断通道"。
-keep class com.cineflow.app.player.PlayerChannel { *; }
-keep class com.cineflow.app.player.Media3Channel { *; }
-keep class com.cineflow.app.system.SystemChannel { *; }

# ---------------------------------------------------------------------------
# 3. Activity / Flutter 入口
# ---------------------------------------------------------------------------
# AndroidManifest 里声明的类由系统按名字实例化，R8 默认已保留，
# 这里显式写出以免将来加 `-repackageclasses` 之类的激进选项时被破坏。
-keep class com.cineflow.app.MainActivity { *; }

# ---------------------------------------------------------------------------
# 4. 回溯友好（可选，但崩溃排查时很值）
# ---------------------------------------------------------------------------
# 保留行号，让 release 崩溃堆栈仍能对到源码行。
# 注意：这**不泄漏**源码（只有行号，没有变量名/方法名）。
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
