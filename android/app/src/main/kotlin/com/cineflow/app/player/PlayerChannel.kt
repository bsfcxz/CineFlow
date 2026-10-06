package com.cineflow.app.player

import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * 播放器原生通道：Flutter 纹理（视频输出）+ MethodChannel 命令 + EventChannel 事件。
 *
 * ## 为什么用 Flutter 纹理而不是 PlatformView
 *
 * 参考 media_kit_video 的 `VideoOutput.java`（本项目原先正在用、已验证可跑）：
 * `TextureRegistry.createSurfaceProducer()` 拿到一个 Flutter 纹理的 Surface，
 * 交给 mpv 当 `wid`。Dart 侧用 `Texture(textureId:)` 显示。
 *
 * 好处（正是 Emby 播放器需要的）：
 *   - 视频是**普通 Flutter 纹理**，弹幕 `CustomPainter` / 手势 / 控制层
 *     天然叠在上面，不需要 PlatformView 的手势仲裁；
 *   - 不需要自己写 EGL（`mpv-android` 与 `media_kit_video` 也都不写）。
 *
 * ## ★ 顺序陷阱（本文件最关键的一处）
 *
 * mpv 的 `wid` 必须在 `mpv_initialize` **之前**设成 option，之后再设不生效。
 * 所以流程被固定为：
 *   1. Dart 调 `createTexture` → 建 SurfaceProducer
 *   2. Surface 可用后 → `MPVLib.attachSurface(surface)`
 *   3. 再 `ensureMpvReady()` → `nativeInit()`（此时 wid 已就绪）
 * 故 `initialize` / `open` 都会先确保纹理已建。
 *
 * ## 命令（MethodChannel `cineflow/player`）
 * | 方法 | 说明 |
 * |---|---|
 * | `createTexture` | 建 Flutter 纹理，返回 textureId（Dart 用 Texture 显示） |
 * | `setSurfaceSize` | 视口变化时同步尺寸 |
 * | `initialize` | 幂等：attachSurface → mpv_create → 选项 → mpv_initialize |
 * | `open` | `{url, headers?}` → `loadfile replace`（headers 走 `http-header-fields`） |
 * | `play` / `pause` / `seek` / `setRate` / `setVolume` |
 * | `setAudioTrack` / `setSubtitleTrack`（`"no"` = 关闭） |
 * | `disposeTexture` / `dispose` | 释放纹理；拆 mpv |
 */
class PlayerChannel(
    private val messenger: BinaryMessenger,
    private val registry: TextureRegistry,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD = "cineflow/player"
        const val EVENT = "cineflow/player/events"
        private const val TAG = "CineFlowMPV"

        @Volatile
        private var eventSink: EventChannel.EventSink? = null

        @Volatile
        private var mpvReady = false

        /**
         * 幂等初始化 mpv。调用前必须已 attachSurface，
         * 否则 mpv 没有渲染目标（画面全黑且不报错）。
         *
         * 选项顺序有讲究：**必须在 `mpv_initialize` 之前**设成 option；
         * 之后再设只是 property（对 `vo` / `gpu-context` / `hwdec`
         * 这类启动期选项无效）。
         */
        @Synchronized
        fun ensureMpvReady(): Boolean {
            if (mpvReady) return true
            MPVLib.nativeCreate()

            // ★ 与 mpv-android 的 initOptions() 对齐：Surface 交给 mpv，
            //   由 mpv 自己建 EGL（gpu-context=android）
            MPVLib.setOptionString("vo", "gpu")
            MPVLib.setOptionString("gpu-context", "android")
            MPVLib.setOptionString("opengl-es", "yes")

            // Android 硬解：与 mpv-android 同款组合
            MPVLib.setOptionString("hwdec", "mediacodec,mediacodec-copy")
            MPVLib.setOptionString(
                "hwdec-codecs",
                "h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1",
            )
            MPVLib.setOptionString("ao", "audiotrack,opensles")

            // 网络缓冲：64MiB 与 mpv-android 一致（Emby 直连常见高码率 4K）
            MPVLib.setOptionString("cache", "yes")
            MPVLib.setOptionString("demuxer-max-bytes", "64MiB")
            MPVLib.setOptionString("demuxer-max-back-bytes", "32MiB")

            // 不让 mpv 读用户 config：行为可预测
            MPVLib.setOptionString("config", "no")
            // 进度由 App 层负责（Emby 有自己的进度接口），别让 mpv 再写一份
            MPVLib.setOptionString("save-position-on-quit", "no")
            MPVLib.setOptionString("idle", "yes")
            MPVLib.setOptionString("force-window", "no")

            // ★ 字幕字体目录 —— 不设的话 libass **找不到任何字体**，
            //   现象是"有字幕轨但整屏不显示字幕"，而 logcat 只给一行
            //   `[mpv/sub/ass] can't find selected font provider`（极易忽略）。
            //   实测本机 4K 片源（mov_text 字幕）就命中了这个坑。
            //   Android 系统字体在 /system/fonts，交给 libass 自行匹配。
            MPVLib.setOptionString("sub-fonts-dir", "/system/fonts")
            // 字幕默认字体名：Android 自带 Roboto，缺字时 libass 会回退到同目录其它字体
            MPVLib.setOptionString("sub-font", "sans-serif")
            // 字幕编码交给 libass 自动探测（外挂 srt 常见 GBK/UTF-8 混用）
            MPVLib.setOptionString("sub-codepage", "auto")

            MPVLib.nativeInit()
            mpvReady = true
            Log.i(TAG, "mpv 已就绪")
            return true
        }

        @Synchronized
        fun teardownMpv() {
            if (!mpvReady) return
            MPVLib.nativeDestroy()
            MPVLib.detachSurface()
            mpvReady = false
            Log.i(TAG, "mpv 已拆机")
        }
    }

    private val methodChannel = MethodChannel(messenger, METHOD)

    /** 当前 Flutter 纹理（同一时刻只允许一个播放器页） */
    private var surfaceProducer: TextureRegistry.SurfaceProducer? = null

    private val surfaceCallback = object : TextureRegistry.SurfaceProducer.Callback {
        override fun onSurfaceAvailable() {
            val producer = surfaceProducer ?: return
            val ok = MPVLib.attachSurface(producer.surface)
            Log.i(TAG, "onSurfaceAvailable: attachSurface=$ok")
        }

        override fun onSurfaceCleanup() {
            // Surface 要没了：先摘掉 mpv 的渲染目标，避免它往已释放的窗口画
            MPVLib.detachSurface()
            Log.i(TAG, "onSurfaceCleanup: detachSurface")
        }
    }

    fun register() {
        methodChannel.setMethodCallHandler(this)
        EventChannel(messenger, EVENT).setStreamHandler(this)
    }

    fun unregister() {
        methodChannel.setMethodCallHandler(null)
        eventSink = null
    }

    // ---------------- EventChannel ----------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        MPVLib.eventListener = { json ->
            // MPVLib 已保证主线程，sink 调用是安全的
            eventSink?.success(json)
        }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        MPVLib.eventListener = null
    }

    // ---------------- 纹理 ----------------

    /**
     * 建纹理并把 Surface 交给 mpv。
     * 必须在 initialize / open 之前调用，否则没有渲染目标。
     */
    private fun createTexture(width: Int, height: Int): Long {
        disposeTexture()
        val producer = registry.createSurfaceProducer()
        surfaceProducer = producer
        producer.setCallback(surfaceCallback)
        producer.setSize(width.coerceAtLeast(1), height.coerceAtLeast(1))
        // setSize 之后回调可能已经触发；这里再确认一次（attachSurface 幂等）
        MPVLib.attachSurface(producer.surface)
        Log.i(TAG, "createTexture: id=${producer.id()} ${width}x$height")
        return producer.id()
    }

    private fun ensureTexture(): Boolean {
        if (surfaceProducer != null) return true
        createTexture(1920, 1080)
        return surfaceProducer != null
    }

    private fun disposeTexture() {
        val producer = surfaceProducer ?: return
        MPVLib.detachSurface()
        try {
            producer.release()
        } catch (e: Throwable) {
            Log.e(TAG, "surfaceProducer.release 失败", e)
        }
        surfaceProducer = null
    }

    // ---------------- MethodChannel ----------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "createTexture" -> {
                    val w = call.argument<Int>("width") ?: 1920
                    val h = call.argument<Int>("height") ?: 1080
                    result.success(createTexture(w, h))
                }

                "setSurfaceSize" -> {
                    val w = (call.argument<Int>("width") ?: 1920).coerceAtLeast(1)
                    val h = (call.argument<Int>("height") ?: 1080).coerceAtLeast(1)
                    surfaceProducer?.setSize(w, h)
                    result.success(true)
                }

                "initialize" -> {
                    ensureTexture()
                    result.success(ensureMpvReady())
                }

                "open" -> {
                    ensureTexture()
                    ensureMpvReady()
                    val url = call.argument<String>("url").orEmpty()
                    if (url.isEmpty()) {
                        result.error("bad_args", "open 缺少 url", null)
                        return
                    }
                    // ★ 115 网盘：headers 必须与取直链时的 UA 逐字节一致，
                    //   且要合并 Set-Cookie，否则 CDN 返回 403。
                    //   漏了它们 = "地址取到了但播不了"，极难排查。
                    val headers = call.argument<Map<String, String>>("headers")
                    if (!headers.isNullOrEmpty()) {
                        // mpv 的 http-header-fields 是逗号分隔的单条字符串
                        val joined = headers.entries.joinToString(",") { "${it.key}: ${it.value}" }
                        MPVLib.setPropertyString("http-header-fields", joined)
                    } else {
                        // 换片要清掉上一片的头，否则 115 的 Cookie 会带到 Emby 请求上
                        MPVLib.setPropertyString("http-header-fields", "")
                    }
                    MPVLib.command(arrayOf("loadfile", url, "replace"))
                    result.success(true)
                }

                "play" -> {
                    MPVLib.setPropertyString("pause", "no")
                    result.success(true)
                }

                "pause" -> {
                    MPVLib.setPropertyString("pause", "yes")
                    result.success(true)
                }

                "seek" -> {
                    val sec = (call.arguments as? Number)?.toDouble() ?: 0.0
                    MPVLib.command(arrayOf("seek", sec.toString(), "absolute"))
                    result.success(true)
                }

                "setRate" -> {
                    val rate = (call.arguments as? Number)?.toDouble() ?: 1.0
                    MPVLib.setPropertyString("speed", rate.toString())
                    result.success(true)
                }

                "setVolume" -> {
                    val vol = (call.arguments as? Number)?.toDouble() ?: 100.0
                    MPVLib.setPropertyString("volume", vol.toString())
                    result.success(true)
                }

                "setAudioTrack" -> {
                    MPVLib.setPropertyString("aid", call.arguments?.toString() ?: "auto")
                    result.success(true)
                }

                "setSubtitleTrack" -> {
                    MPVLib.setPropertyString("sid", call.arguments?.toString() ?: "auto")
                    result.success(true)
                }

                "setProperty" -> {
                    val name = call.argument<String>("name").orEmpty()
                    val value = call.argument<String>("value").orEmpty()
                    if (name.isEmpty()) {
                        result.error("bad_args", "setProperty 缺少 name", null)
                        return
                    }
                    MPVLib.setPropertyString(name, value)
                    result.success(true)
                }

                "command" -> {
                    val args = (call.arguments as? List<*>)?.map { it.toString() }?.toTypedArray()
                        ?: emptyArray()
                    MPVLib.command(args)
                    result.success(true)
                }

                "disposeTexture" -> {
                    disposeTexture()
                    result.success(true)
                }

                "dispose" -> {
                    MPVLib.eventListener = null
                    disposeTexture()
                    teardownMpv()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            // 不让异常穿过 MethodChannel（会变成 Dart 侧难以理解的错误）
            Log.e(TAG, "onMethodCall ${call.method} 失败", e)
            result.error("native_error", e.message ?: e.toString(), null)
        }
    }
}
