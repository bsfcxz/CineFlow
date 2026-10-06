package com.cineflow.app.player

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface

/**
 * mpv JNI 桥（Kotlin 侧）。C 实现见 app/src/main/cpp/cineflow_mpv.c。
 *
 * 架构参考 mpv-android（MIT）https://github.com/mpv-android/mpv-android
 * 的 `MPVLib.kt`：`object` 持有 `external fun`，C 事件线程通过
 * `@JvmStatic onEvent` 回调。
 *
 * 与 mpv-android 一致：渲染走 **Surface → wid**，
 * 由 mpv 自己用 `gpu-context=android` 建 EGL，我们不碰 GL/EGL。
 * 差异：mpv-android 用 SurfaceView；本工程用 Flutter 纹理的 Surface
 * （与 media_kit_video 的 VideoOutput.java 同款），
 * 这样视频是普通 Flutter 纹理，弹幕/手势/控制层天然叠在上面。
 *
 * 事件一律**切回主线程**再分发，保证 EventChannel sink 调用线程安全。
 */
object MPVLib {
    private const val TAG = "CineFlowMPV"

    private val mainHandler = Handler(Looper.getMainLooper())

    /** Dart EventChannel 的 sink 回调（JSON 字符串）；由 PlayerChannel 装配 */
    @Volatile
    var eventListener: ((String) -> Unit)? = null

    /** 挂载渲染 Surface。返回 true 表示可以 initialize mpv 了。 */
    external fun attachSurface(surface: Surface?): Boolean

    /** Surface 销毁前必须调用，否则 mpv 会往已释放的 ANativeWindow 上画。 */
    external fun detachSurface()

    external fun nativeCreate()
    external fun nativeInit()
    external fun nativeDestroy()
    external fun setOptionString(option: String, value: String)
    external fun setPropertyString(property: String, value: String)
    external fun getPropertyString(property: String): String
    external fun command(args: Array<String>)

    init {
        // 顺序不能反：cineflow_mpv 依赖 libmpv.so 的符号
        System.loadLibrary("mpv")
        System.loadLibrary("cineflow_mpv")
        Log.i(TAG, "libmpv + cineflow_mpv 已加载")
    }

    /** C 事件线程调用（JSON 事件）→ 主线程分发 */
    @JvmStatic
    fun onEvent(json: String) {
        mainHandler.post { eventListener?.invoke(json) }
    }
}
