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

            // ---- ★ HDR / 杜比视界的 tone-mapping 链路（2026-10-09）----
            //
            // ## 为什么必须补这一段
            // 我们的自动适配（`KernelAutoSelect` 规则 0）把 **DV/HDR 片源
            // 路由到 mpv**，理由是"mpv 有软件回退 + tone-mapping"。
            // 但此前**一项 tone-mapping 参数都没配** ⇒ mpv 走默认值，
            // 等于"把它送来却不给它干活的工具"。
            //
            // ## 取值来源
            // 全部**实测存在于本构建的 libmpv.so**（逐个 grep 选项名与取值，
            // 不凭文档/记忆）：
            //   · `tone-mapping` 的 11 种取值全在（bt.2390/bt.2446a/spline/
            //     reinhard/hable/gamma/linear/clip/mobius/st2094-40/st2094-10）
            //   · `hdr-compute-peak` / `target-peak` / `gamut-mapping-mode` /
            //     `target-prim` / `tone-mapping-mode` 选项名均在
            //
            // ## 各参数作用
            // · `bt.2390`：ITU-R BT.2390 曲线，HDR→SDR 的**参考级**映射
            // · `hdr-compute-peak=yes`：**逐帧**分析峰值亮度，避免高光过曝
            //   （默认 off 时用固定峰值，亮场景容易死白）
            // · `target-peak=auto`：让 mpv 按显示设备能力定目标亮度
            // · `gamut-mapping-mode=auto`：BT.2020 → 设备色域（P3/sRGB）
            // · `target-prim=auto`：目标色域原色，交给 mpv 判断
            //
            // ## 局限性（如实说明）
            // 本构建 `-Dlibplacebo=disabled`（已从二进制提取的编译配置确认），
            // 故这些参数走的是 **`vo=gpu` 的内置实现**，精度**不如
            // `gpu-next`（libplacebo）**。`target-colorspace-hint` 等
            // gpu-next 专属选项在本构建里**不存在**（0 命中），故未添加。
            // ⇒ 想要更高精度需重建带 libplacebo 的 libmpv（见
            //   `docs/DUAL-KERNEL.md` 与第二步计划）。
            MPVLib.setOptionString("tone-mapping", "bt.2390")
            MPVLib.setOptionString("tone-mapping-mode", "auto")
            MPVLib.setOptionString("hdr-compute-peak", "yes")
            MPVLib.setOptionString("target-peak", "auto")
            MPVLib.setOptionString("gamut-mapping-mode", "auto")
            MPVLib.setOptionString("target-prim", "auto")

            // ---- ★ 流畅度：视频同步与插帧（2026-10-09）----
            //
            // ## 为什么加
            // 此前未设 `video-sync` ⇒ 走默认 `audio`（以音频时钟为主）。
            // 在 Android 上**帧率与刷新率不匹配时会产生周期性微卡**
            // （24fps 片源在 60Hz 屏上尤其明显：每 2.5 帧一次抖动）。
            //
            // ## 各参数作用
            // · `display-resample`：视频时钟**跟随显示刷新率**，
            //   由 mpv 微小拉伸音视频以对齐 —— 消除周期性微卡
            // · `interpolation=yes`：运动插值（**仅在 display-resample 下生效**）。
            //   它做的是**运动平滑**，不是"锐化/美化"，不损失画质信息
            // · `tscale=box`：插值核用最省 GPU 的 box
            //   （`oversample` 更省但会有轻微抖动，box 是官方推荐的平衡点）
            MPVLib.setOptionString("video-sync", "display-resample")
            MPVLib.setOptionString("interpolation", "yes")
            MPVLib.setOptionString("tscale", "box")

            // 只允许**渲染端**丢帧：解码器不丢已解出的完整帧。
            // 默认 `decoder+vo` 会在掉帧时连解码帧一起丢 ⇒ 画质损失。
            // ⚠️ 若低端机上出现"解码来不及导致持续卡顿"，**先回调这一项**。
            MPVLib.setOptionString("framedrop", "vo")

            // 音频缓冲：默认 0.2s，切后台/系统卡顿时容易爆音。
            // 0.5s 增加 300ms 音频延迟（对口型无影响），不损失画质。
            MPVLib.setOptionString("audio-buffer", "0.5")

            // 网络缓冲（2026-10-09 分档调整）
            //
            // ## 从 64/32 提到 128/64 的理由
            // Emby 直连常见高码率 4K（30–80 Mbps），64MiB 约合 6–17 秒缓冲；
            // 提到 128MiB 后网络波动更能扛。
            //
            // ## `demuxer-max-back-bytes` 特别说明
            // 它是**回退缓冲** —— **往回拖进度条能不能立刻出画面就靠它**。
            // 原 32MiB，提到 64MiB 让"往回拖"更顺（这是用户高频操作）。
            //
            // ⚠️ 内存代价：两项合计上限约 192MiB。K40（8GB）无压力；
            //    若将来支持 4GB 老机，**这里的两个值要按机型降档**
            //    （下限建议 64/32，即本轮之前的取值）。
            //    注意这与"不做内核预创建"不冲突 —— 那是**两个内核同时活着**，
            //    这里只是单内核内部的缓冲上限。
            MPVLib.setOptionString("cache", "yes")
            MPVLib.setOptionString("demuxer-max-bytes", "128MiB")
            MPVLib.setOptionString("demuxer-max-back-bytes", "64MiB")
            // 缓存时长上限（秒）：避免缓冲无限堆积占用内存
            MPVLib.setOptionString("cache-secs", "30")

            // ★ 起播优化（2026-10-08，真机埋点驱动，用户反馈"起播慢"）
            //
            // ## 实测问题（3 次采样中位）
            //   DEMUX_DONE  = 4255ms  ← 打开 URL → 容器探测完成
            //   FIRST_FRAME = 4513ms  ← → 首帧渲染
            //   点到出画面   = 9087ms
            //   而 Dart 命令链只占 314ms ⇒ 慢在 mpv 内部，不在网络请求层
            //
            // ## 根因
            // ffmpeg 默认 `analyzeduration` = **5 秒**：要读够 5 秒数据
            // 才确定流信息（轨道/编码/时长）。对**网络源**这就是纯等待，
            // 与实测的 4.2 秒高度吻合。
            //
            // ## 取舍
            // 分析窗口越短，**冷门容器/异常流的探测准确率越低**
            // （可能误判轨道）。1 秒对 Emby 直连的常见容器（mp4/mkv）足够；
            // 若将来遇到"轨道识别不全/时长不对"，**先回调这一项**。
            MPVLib.setOptionString("demuxer-lavf-analyzeduration", "1")
            // 探测缓冲同步收紧（ffmpeg 默认 5MB）：网络源读满 5MB 也要时间。
            // 2MB 足够识别容器头部。
            MPVLib.setOptionString("demuxer-lavf-probesize", "2097152")
            //
            // ⚠️ 本轮**不动** `cache-pause` 系列 —— 一次只改一个变量，
            //    否则分不清收益来自"分析窗口"还是"缓冲等待"。

            // 网络 I/O 超时：默认 60s 太长，遇到 STRM 死源要干等一分钟才报错。
            // 15s 与 Dart 侧 `PlayerPage._startTimeoutDuration` 对齐 ——
            // 两层都设的意义：mpv 这层管**连接/读取**超时（能主动断开），
            // Dart 那层管**用户观感**（既无时长也无进度就切转码/报错）。
            // 缺任何一层都会出现"能恢复但用户已经盯着灰屏很久"的体验。
            MPVLib.setOptionString("network-timeout", "15")

            // 不让 mpv 读用户 config：行为可预测
            MPVLib.setOptionString("config", "no")

            // ⚠️ 曾在此加过 `log-file` + `msg-level` 用于诊断，**已移除**：
            //   · App 只有 `INTERNET` 权限，写不了 `/sdcard/...`
            //     （`files` 目录不存在 ⇒ 那条配置是**死的**）
            //   · 而"选项是否生效"最终用**别的方式**确认了：
            //     `getProperty` 回读通道（见 `PlayerKernel.getOption`）
            //   ⇒ 不留"看起来在做事、实际没做事"的配置。
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
            // ⚠️ 这里不写日志：Flutter release 的 R8 会剥离**全部** `Log.*`
            // （dex 取证 `Log;->i/w/e/d(` 均不存在）⇒ 写了也看不到。
            // 需要观测 mpv 状态请用 `getProperty` method + Dart 侧 debugPrint。
            return true
        }

        @Synchronized
        fun teardownMpv() {
            if (!mpvReady) return
            MPVLib.nativeDestroy()
            MPVLib.detachSurface()
            mpvReady = false
            Log.e(TAG, "mpv 已拆机")  // 同"mpv 已就绪"：需在 release 可见
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

                // ★ 只读回读 mpv 属性（2026-10-09）
                //
                // ## 为什么需要它
                // 排查"选项配了却没生效"必须有回读手段。
                // 而 **Kotlin 侧写不出日志** —— Flutter release 的 R8 会剥离
                // **全部** `Log.*` 调用（dex 取证：`Log;->i/w/e/d(` 均不存在），
                // 故自检结果只能**经由 Dart 侧**输出（`debugPrint` 可见）。
                //
                // `MPVLib.getPropertyString` 早已存在，只是从未暴露给 Dart。
                "getProperty" -> {
                    val name = call.argument<String>("name").orEmpty()
                    if (name.isEmpty()) {
                        result.error("bad_args", "getProperty 缺少 name", null)
                        return
                    }
                    result.success(
                        try {
                            MPVLib.getPropertyString(name)
                        } catch (e: Throwable) {
                            // 选项不存在 / 该阶段不可读 → 返回空串而不是抛异常
                            // （调用方据此判定"未生效"，不该因此中断播放）
                            ""
                        },
                    )
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
