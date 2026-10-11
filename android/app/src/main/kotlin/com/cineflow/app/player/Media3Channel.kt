package com.cineflow.app.player

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.datasource.DefaultHttpDataSource
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import org.json.JSONArray
import org.json.JSONObject

/**
 * **Media3（androidx.media3 / ExoPlayer）播放内核** —— 双内核的第二实现。
 *
 * ## 为什么要有它（用户明确要求 "mpv + androidx.media 双内核"）
 *
 * 两个内核各有不可替代的场景：
 *
 * | 场景 | 更合适的内核 |
 * |---|---|
 * | 本地/网络几乎任意格式、外挂字幕、画面滤镜、音视频延迟 | **mpv** |
 * | 需要与系统媒体会话集成（通知栏/蓝牙键/音频焦点）、DRM | **Media3** |
 *
 * mpv 是自己打包的完整播放器，能力全但**绕过了 Android 的媒体框架**；
 * Media3 是 Android 官方栈，**与系统集成天然顺畅**但格式支持与滤镜能力弱。
 *
 * ## 输出方式：与 mpv 内核**完全一致**（Flutter Texture）
 *
 * Media3 的 `ExoPlayer.setVideoSurface(surface)` 接受任意 Surface，
 * 而 Flutter 的 `TextureRegistry.SurfaceProducer` 正好给出一个 Surface。
 * 于是**两个内核共用同一条"Dart 用 Texture 显示"的路径** ——
 * Dart 侧不需要知道当前是哪个内核（`viewType` 都是 null）。
 *
 * 这比"Media3 用 PlatformView"更好：PlatformView 在 Flutter 里有
 * 合成开销与手势穿透问题，而 Texture 只是一张贴图。
 *
 * ## ⚠️ 能力差异（Dart 侧 `supports()` 必须如实声明）
 *
 * Media3 **没有**这些能力，Dart 侧据此禁用对应 UI：
 *   · 画面滤镜（亮度/对比度/饱和度/色相）→ 需自叠 GL 层，本内核不做
 *   · 音频延迟 / 字幕延迟 → 无等价属性（mpv 有 `audio-delay`/`sub-delay`）
 *   · 切换硬/软解 → 只能通过重建 `RenderersFactory`，运行中不可切
 *
 * **如实声明比"假装支持"重要**：UI 会据此把入口置灰，
 * 用户看到的是"这个内核不支持"而不是"点了没反应"。
 */
class Media3Channel(
    private val context: Context,
    private val registry: TextureRegistry,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "CF-Media3"
        const val METHOD = "cineflow/media3"
        const val EVENT = "cineflow/media3/events"

        /** 与 mpv 内核保持相同的上报周期（10s，对齐 Emby 的进度上报约定）。 */
        private const val PROGRESS_INTERVAL_MS = 250L

        /**
         * 默认 UA。
         *
         * ⚠️ 某些服务端会按 UA 做能力判定（Emby 的 `DeviceProfile` 校验、
         *    115 CDN 的 UA 绑定）。用 OkHttp/ExoPlayer 的默认 UA 容易被
         *    当作陌生客户端，故显式声明为本应用。
         */
        private const val DEFAULT_UA = "CineFlow/1.0 (Android; Media3)"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var player: ExoPlayer? = null
    private var surfaceProducer: TextureRegistry.SurfaceProducer? = null
    private var eventSink: EventChannel.EventSink? = null

    /** 当前媒体 URL 与请求头（重建 `MediaItem` 时需要，见 `addExternalSubtitle`）。 */
    private var mediaUrl: String? = null
    private var currentHeaders: Map<String, String> = emptyMap()

    /**
     * 已注册的**外挂字幕**（Emby `IsExternal=true`）。
     *
     * ## 为什么要缓存
     * Media3 的字幕配置是**创建 `MediaItem` 时固定**的
     * （`MediaItem.SubtitleConfigurations`），运行中不能"追加"。
     * ⇒ 只能记下来，然后重建 `MediaItem` 并 seek 回原位置。
     */
    private val externalSubs = mutableListOf<ExternalSub>()

    /** 一条外挂字幕（**url 含 api_key ⇒ 绝不写入日志**）。 */
    private data class ExternalSub(
        val url: String,
        val title: String?,
        val language: String?,
    )

    /** 请求头（115 网盘的 UA 绑定与 Cookie 必须透传，见 ADR 0007）。 */
    /// 待应用起始位置（ms）。open 时在 prepare **之前** 消费。
    private var pendingStartMs = 0L

    /** 上一次上报的状态，避免重复推同一份快照。 */
    private var lastPositionMs = 0L
    private var lastPlaying = false
    private var lastBuffering = false
    private var lastDurationMs = 0L

    private val progressTicker = object : Runnable {
        override fun run() {
            emitState(force = false)
            mainHandler.postDelayed(this, PROGRESS_INTERVAL_MS)
        }
    }

    private val listener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            emitState(force = true)
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            emitState(force = true)
            if (playbackState == Player.STATE_ENDED) {
                eventSink?.success(JSONObject().apply {
                    put("type", "end-file")
                    put("reason", "eof")
                }.toString())
            }
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            eventSink?.success(JSONObject().apply {
                put("type", "property")
                put("name", "video-size")
                put("data", JSONObject().apply {
                    put("width", videoSize.width)
                    put("height", videoSize.height)
                })
            }.toString())
        }

        override fun onTracksChanged(tracks: Tracks) {
            emitTracks(tracks)
        }

        /** ★★ **字幕 cue 到达**（PGS 图形字幕的唯一出口）。
         *
         * ## 为什么必须自己处理（真机取证，2026-10-11）
         * Media3 **能解析** PGS（`PgsParser`），但**渲染**靠 `SubtitleView`
         *（`media3-ui`）。而本项目**不引 `media3-ui`** ——
         * 视频走 `setVideoSurface(Flutter Texture)`，**没有 View 层**。
         * ⇒ 真机现象：`选轨 3 index=1 → ... mime=application/x-media3-cues`
         *   选轨成功、cue 也解析了，但**画面里什么都没有**（无人渲染）。
         *
         * ## 判据：`cue.bitmap != null` 就是图形字幕
         * · PGS / VOBSUB ⇒ `bitmap != null`（要按位图绘制）
         * · SRT / ASS ⇒ `bitmap == null` + `text != null`（按文本绘制）
         *
         * ⇒ 本轮先把 cue **上报到 Dart**，由 Flutter 侧绘制（我们的弹幕层
         *   已是"在视频上叠加自绘内容"的成熟通路）。
         */
        override fun onCues(cueGroup: androidx.media3.common.text.CueGroup) {
            emitCues(cueGroup)
        }

        /** 把 cue 转成 JSON 上报（位图转 base64 PNG，文本直传）。
         *
         * ⚠️ 位图**必须转 PNG 再传**：`Cue.bitmap` 是 `Bitmap`，
         *    跨 MethodChannel 只能传字节。PNG 无损且体积可接受
         *    （PGS 一帧通常几 KB ~ 几十 KB）。
         */
        private fun emitCues(group: androidx.media3.common.text.CueGroup) {
            val arr = JSONArray()
            for (cue in group.cues) {
                val o = JSONObject()
                cue.text?.let { o.put("text", it.toString()) }
                val bmp = cue.bitmap
                if (bmp != null) {
                    try {
                        val bos = java.io.ByteArrayOutputStream()
                        bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, bos)
                        o.put("png", android.util.Base64.encodeToString(
                            bos.toByteArray(), android.util.Base64.NO_WRAP))
                        o.put("w", bmp.width)
                        o.put("h", bmp.height)
                    } catch (e: Exception) {
                        Log.w(TAG, "cue 位图编码失败: ${e.message}")
                        continue
                    }
                }
                o.put("line", cue.line.toDouble())
                o.put("lineType", cue.lineType)
                arr.put(o)
            }
            eventSink?.success(JSONObject().apply {
                put("type", "cues")
                put("data", arr)
            }.toString())
        }

        override fun onPlayerError(error: PlaybackException) {
            Log.w(TAG, "播放错误: ${error.errorCodeName} ${error.message}")
            eventSink?.success(JSONObject().apply {
                put("type", "log")
                put("level", "error")
                put("text", error.message ?: error.errorCodeName)
            }.toString())
        }
    }

    /**
     * ★★ 音频/字幕轨**编码不受支持**时上报（真机实测的关键缺口）。
     *
     * ## 为什么必须单独一个 listener（用户报障的直接原因）
     * 播《复仇者联盟》时 Media3 报：
     * ```
     * MediaCodecAudioRenderer error, index=1,
     *   format=Format(3, 国语, null, audio/true-hd, ...),
     *   format_supported=NO_UNSUPPORTED_TYPE
     * ```
     * 但**用户什么都看不到** —— 只是"没声音"，无从知道原因与对策。
     *
     * ## 为什么不能用 `Player.Listener`
     * `onAudioInputFormatChanged` 属 **`AudioRendererEventListener`**
     *（`androidx.media3.exoplayer.audio`），**不在 `Player.Listener` 上**。
     * 已在 `media3-exoplayer-1.4.1.aar` 的 `classes.jar` 里核实：
     * 该符号只出现在 `androidx/media3/exoplayer/audio/AudioRendererEventListener`。
     * ⇒ 用 `AnalyticsListener`（它转发渲染器事件）。
     *
     * ## 上报的是**可行动信息**（不是"出错了"）
     * "该音轨编码在此内核上解不了，已跳过，请换一条" ——
     * 用户据此能自己解决。
     */
    private val analyticsListener = object : AnalyticsListener {
        override fun onAudioInputFormatChanged(
            eventTime: AnalyticsListener.EventTime,
            format: Format,
            decoderReuseEvaluation: DecoderReuseEvaluation?,
        ) {
            val mime = format.sampleMimeType ?: return
            // 已知 Android/MediaCodec 不支持的编码
            // （真机实测 audio/true-hd → NO_UNSUPPORTED_TYPE）
            val unsupported = mime.contains("true-hd") ||
                mime.contains("truehd") ||
                mime.contains("mlp")
            if (!unsupported) return
            Log.w(TAG, "音频轨编码不受支持: $mime（label=${format.label}）")
            // ⚠️ 用**独立事件类型** —— `log` 类型 Dart 侧是**忽略**的，
            //    那正是"用户看不到任何提示"的原因
            eventSink?.success(JSONObject().apply {
                put("type", "trackUnsupported")
                put("kind", "audio")
                put("mime", mime)
                put("label", format.label ?: "")
                put(
                    "message",
                    "该音轨编码（${mime.substringAfterLast('/')}）" +
                        "当前播放内核无法解码，已跳过。请换一条音轨。",
                )
            }.toString())
        }
    }

    fun register(flutterEngine: FlutterEngine) {        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, METHOD).setMethodCallHandler(this)
        EventChannel(messenger, EVENT).setStreamHandler(this)
    }

    // ---------------- EventChannel ----------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        startTicker()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        stopTicker()
    }

    private fun startTicker() {
        mainHandler.removeCallbacks(progressTicker)
        mainHandler.postDelayed(progressTicker, PROGRESS_INTERVAL_MS)
    }

    private fun stopTicker() {
        mainHandler.removeCallbacks(progressTicker)
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
                "open" -> {
                    val url = call.argument<String>("url").orEmpty()
                    // ★ 记住当前 URL（重建 MediaItem 加外挂字幕时要用）
                    mediaUrl = url
                    // ★ 换片时清掉上一片的外挂字幕（否则字幕会串到下一片）
                    externalSubs.clear()
                    @Suppress("UNCHECKED_CAST")
                    currentHeaders = (call.argument<Map<String, String>>("headers")
                        ?: emptyMap()).filterValues { it != null }
                    // ★★ 起始位置随 open 一起给（起播优化，2026-10-10）
                    //
                    // ## 为什么要在这里（而不是 open 完再 seekTo）
                    // `ExoPlayer.setStartPosition()` 必须在 `prepare()`
                    // **之前**调用，否则会被忽略。放在这里 ⇒ 播放器
                    // **直接从目标位置开始缓冲**，省掉"先缓冲片头再跳"
                    // 的一整段（4K 片源上这是数秒）。
                    //
                    // ## 与 Dart 侧的分工
                    // Dart 的 `open(start:)` 把值传下来；≤3s 视为"从头播"
                    //（与 mpv 侧同一阈值），不调 setStartPosition 避免无谓调用。
                    val startSec = call.argument<Number>("start")?.toDouble() ?: 0.0
                    pendingStartMs = if (startSec > 3) (startSec * 1000).toLong() else 0L
                    open(url)
                    result.success(true)
                }
                "play" -> { player?.play(); result.success(true) }
                "pause" -> { player?.pause(); result.success(true) }
                "seek" -> {
                    val seconds = call.arguments as? Double ?: 0.0
                    player?.seekTo((seconds * 1000).toLong())
                    emitState(force = true)
                    result.success(true)
                }
                "setRate" -> {
                    val rate = call.arguments as? Double ?: 1.0
                    player?.setPlaybackSpeed(rate.toFloat())
                    result.success(true)
                }
                "setVolume" -> {
                    // ⚠️ 单位换算：Dart 侧 0–100，Media3 是 0.0–1.0。
                    //    不换算的话 Dart 传 70 会被当作"70 倍音量"（实际被钳到 1.0），
                    //    表现为"一调就满音量"。
                    val v = call.arguments as? Double ?: 100.0
                    player?.volume = (v / 100.0).coerceIn(0.0, 1.0).toFloat()
                    result.success(true)
                }
                "setAudioTrack" -> {
                    val id = call.arguments as? String
                    selectAudioTrack(id)
                    result.success(true)
                }
                "setSubtitleTrack" -> {
                    val id = call.arguments as? String
                    selectSubtitleTrack(id)
                    result.success(true)
                }
                // ★ 外挂字幕（Emby `IsExternal=true` 的独立字幕文件）
                //
                // ## 为什么需要原生侧参与（Media3 的硬约束）
                // Media3 的字幕配置是**创建 `MediaItem` 时固定**的
                // （`MediaItem.SubtitleConfigurations`），运行中无法"追加一条"。
                // ⇒ 只能**记住**它，然后重建 `MediaItem` 并 seek 回原位置。
                //
                // ⚠️ 代价：重建会**短暂中断播放**（重新 prepare）。
                //    这是 Media3 架构决定的，不是实现偷懒 —— mpv 那边用
                //    `sub-add` 就是**无中断**的（两个内核的能力差异，
                //    已在 EngineFeature.externalSubtitle 之外如实记录）。
                "addExternalSubtitle" -> {
                    val url = call.argument<String>("url").orEmpty()
                    val title = call.argument<String>("title")
                    val lang = call.argument<String>("language")
                    val select = call.argument<Boolean>("select") ?: false
                    if (url.isEmpty()) {
                        result.error("bad_args", "addExternalSubtitle 缺少 url", null)
                        return
                    }
                    // ⚠️ 只记 title/lang，**不记 url 正文**（含 api_key）
                    Log.i(TAG, "addExternalSubtitle: title=${title ?: "-"} " +
                        "lang=${lang ?: "-"} select=$select（url 已省略）")
                    externalSubs.add(ExternalSub(url, title, lang))
                    // 有正在播的媒体才需要重建（否则下次 open 自然带上）
                    val rebuilt = if (player != null && mediaUrl != null) {
                        rebuildWithExternalSubs(select)
                    } else {
                        true
                    }
                    result.success(rebuilt)
                }

                "removeExternalSubtitles" -> {
                    externalSubs.clear()
                    if (player != null && mediaUrl != null) {
                        rebuildWithExternalSubs(false)
                    }
                    result.success(true)
                }
                "setAspectMode" -> {
                    // Media3 的画面比例由**渲染 View** 决定，而我们是
                    // `setVideoSurface`（无 View）→ 由 Dart 侧用
                    // `AspectRatio`/`FittedBox` 实现。故这里只记下值。
                    result.success(true)
                }
                "setDecodeMode" -> {
                    // ⚠️ 运行中不可切换硬/软解：Media3 需重建 RenderersFactory。
                    //    Dart 侧 `supports(decodeMode)` 返回 false → UI 已禁用入口。
                    //    这里如实返回失败，不假装成功。
                    result.error("unsupported",
                        "Media3 内核不支持运行中切换解码方式", null)
                }
                "setVideoFilters", "setAudioDelay", "setSubtitleDelay" -> {
                    // 同上：Media3 无等价能力，Dart 侧已声明不支持。
                    result.error("unsupported",
                        "${call.method} 在 Media3 内核中不可用", null)
                }
                "setProperty" -> result.error("unsupported",
                    "Media3 内核不支持 mpv 风格的 property 设置", null)
                "command" -> result.error("unsupported",
                    "Media3 内核不支持 mpv 风格的命令", null)
                "dispose" -> {
                    releasePlayer()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "处理 ${call.method} 失败", e)
            result.error("media3_error", e.message, null)
        }
    }

    // ---------------- 纹理 ----------------

    /**
     * 构造 `MediaItem`（**带已注册的外挂字幕**）。
     *
     * ## 为什么抽成方法（而不是就地 `MediaItem.fromUri`）
     * 两处需要构造：① `open()` ② 加/删外挂字幕后的重建。
     * 若两处各写一份，忘了带外挂字幕的那处会让字幕"时有时无"。
     *
     * ⚠️ 外挂字幕的 `url` 由 Emby 的 `DeliveryUrl` 提供，**含 api_key**。
     */
    @UnstableApi
    private fun mediaItemFor(url: String): MediaItem {
        val builder = MediaItem.Builder().setUri(Uri.parse(url))
        if (externalSubs.isNotEmpty()) {
            val configs = externalSubs.map { s ->
                val b = MediaItem.SubtitleConfiguration.Builder(Uri.parse(s.url))
                    // ⚠️ 必须指定 MIME：Emby 的 DeliveryUrl 常以 `.srt`
                    //    结尾但**也可能带查询串**，Media3 从 URL 猜不可靠。
                    //    srt 是外挂字幕的最常见形态。
                    .setMimeType(MimeTypes.APPLICATION_SUBRIP)
                if (s.language != null && s.language.isNotEmpty()) {
                    b.setLanguage(s.language)
                }
                if (s.title != null && s.title.isNotEmpty()) {
                    b.setLabel(s.title)
                }
                b.build()
            }
            builder.setSubtitleConfigurations(configs)
        }
        return builder.build()
    }

    /**
     * 用"当前 URL + 最新外挂字幕集合"重建 MediaItem（保留播放位置）。
     *
     * ## 为什么必须重建（Media3 的架构约束，不是实现偷懒）
     * `MediaItem.SubtitleConfigurations` **只能在创建时设定**，运行中无法追加。
     * 而 mpv 有 `sub-add` 命令、无中断 —— 这是两个内核的真实能力差异。
     *
     * ⚠️ 代价：重建会**短暂中断播放**（重新 prepare + seek）。
     *    对"打开外挂字幕"这种低频操作是可接受的；
     *    若将来要消除它，唯一路径是改用 Media3 的
     *    `MergingMediaSource` 把字幕源拼进去（同样需要重建，无本质差别）。
     */
    @UnstableApi
    private fun rebuildWithExternalSubs(select: Boolean): Boolean {
        val url = mediaUrl ?: return false
        val p = player ?: return false
        val pos = p.currentPosition
        val wasPlaying = p.isPlaying
        try {
            p.setMediaItem(mediaItemFor(url), pos)
            p.prepare()
            if (wasPlaying) p.play()
            Log.i(TAG, "rebuildWithExternalSubs: 重建完成，保留位置 ${pos}ms，" +
                "外挂字幕 ${externalSubs.size} 条，select=$select")
            return true
        } catch (e: Throwable) {
            Log.e(TAG, "rebuildWithExternalSubs 失败（非致命）", e)
            return false
        }
    }

    private fun createTexture(width: Int, height: Int): Long {
        disposeTexture()
        val producer = registry.createSurfaceProducer()
        surfaceProducer = producer
        producer.setSize(width.coerceAtLeast(1), height.coerceAtLeast(1))
        // Surface 交给 ExoPlayer；player 可能尚未创建，open() 时会再设一次。
        player?.setVideoSurface(producer.surface)
        Log.i(TAG, "createTexture: id=${producer.id()} ${width}x$height")
        return producer.id()
    }

    private fun disposeTexture() {
        surfaceProducer?.release()
        surfaceProducer = null
    }

    // ---------------- 播放器 ----------------

    private fun ensurePlayer(): ExoPlayer {
        player?.let { return it }
        // 用 DefaultRenderersFactory：默认启用 MediaCodec 硬解，
        // 硬解失败时自动回退软解（Media3 的默认行为）。
        val renderers = DefaultRenderersFactory(context)
            .setEnableDecoderFallback(true)

        val httpFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15_000)   // 与 mpv 内核的 network-timeout 对齐
            .setReadTimeoutMs(15_000)
            .setUserAgent(DEFAULT_UA)

        val sourceFactory = DefaultMediaSourceFactory(
            androidx.media3.datasource.DefaultDataSource.Factory(context, httpFactory)
        )

        // ★★ **必须显式开启"内嵌字幕解析"**（否则字幕轨永远没有 cue）
        //
        // ## 真机事故（2026-10-11，《复仇者联盟》PGS 字幕不显示）
        // 现象链：
        // 1. 选轨**成功**：`选轨 3 index=1 → ... mime=application/x-media3-cues`
        // 2. **但 `onCues` 一次都没触发** ⇒ 画面里什么都没有
        //
        // ## 根因：Media3 1.4 默认**不解析**内嵌字幕
        // Media3 从 1.0 起把字幕处理改为"延迟到 `SubtitleParser`"，
        // **内嵌字幕**（容器里的 PGS/SUBRIP 轨）需要显式提供
        // `SubtitleParser.Factory` —— 注意官方 API 名带
        // **`experimental`** 前缀（接口未稳定）：
        // ```
        // DefaultMediaSourceFactory.setSubtitleParserFactory(f)
        // ```
        // ⚠️ **方法名不带 `experimental` 前缀** —— 我第一版按记忆写成
        //   `experimentalSetSubtitleParserFactory`，编译直接
        //   `Unresolved reference`。已用 `javap` 从
        //   `media3-exoplayer-1.4.1.aar` 的 `classes.jar` 核实真实签名：
        //   ```
        //   public DefaultMediaSourceFactory setSubtitleParserFactory(
        //       androidx.media3.extractor.text.SubtitleParser$Factory)
        //   ```
        //   （教训：**API 名必须从产物核实，不能凭记忆**。）
        // 不设置时，Media3 只把字幕轨**列在 `Tracks` 里**（所以面板上
        // 8 条字幕都在），但**不产出 cue** ⇒ 依赖 cue 的渲染通路全程静默。
        //
        // ## 为什么用 `DefaultSubtitleParserFactory`
        // 它是 `media3-extractor` 里的**总厂**，按 MIME 分派到：
        // · `PgsParser`（**PGS 图形字幕** ← 这部片 8 条全是 PGS）
        // · `SubripParser` / `SsaParser` / `WebvttParser` / `Tx3gParser`
        // ⇒ 一次注册覆盖全部格式（这些类已核实存在于
        //   `media3-extractor-1.4.1.aar`）。
        //
        // ⚠️ 与用户报障的对应：这就是"别的播放器能显示、
        //    我们显示不出来"的直接原因之一。
        try {
            sourceFactory.setSubtitleParserFactory(
                androidx.media3.extractor.text.DefaultSubtitleParserFactory()
            )
            Log.i(TAG, "已开启内嵌字幕解析（含 PGS）")
        } catch (e: Throwable) {
            // ⚠️ 兜底：不能让"字幕解析配置失败"拖垮**整个播放**
            Log.w(TAG, "开启内嵌字幕解析失败（降级为无内嵌字幕）: ${e.message}")
        }

        // ★★ 起播优化：`LoadControl` 调优（2026-10-10）
        //
        // ## 默认值的问题
        // Media3 默认 `DefaultLoadControl`：
        //   bufferForPlaybackMs = **2500**  ← 起播前要缓冲够 2.5 秒才开播
        //   bufferForPlaybackAfterRebufferMs = 5000
        //   minBufferMs = 50000 / maxBufferMs = 50000
        // ⇒ 那 2.5 秒对**已经就绪**的源是纯等待。
        //
        // ## 本轮的取值（起播门槛 2500 → 1000）
        // ```
        // setBufferDurationsMs(
        //   minBufferMs = 15000,             // 稳态最少缓冲
        //   maxBufferMs = 50000,             // 稳态最多缓冲（与默认一致）
        //   bufferForPlaybackMs = 1000,      // ★ 起播门槛 2.5s → 1s
        //   bufferForPlaybackAfterRebufferMs = 2000,  // 卡顿恢复门槛
        // )
        // ```
        // 真机实测依据：4K hevc 片源走 Media3 内核时
        // `DEMUX_DONE=10465ms / FIRST_FRAME=2756ms`（点到出画面 13.5 秒）
        // ⇒ 至少 2.5 秒是这里的固定门槛。
        //
        // ## ⚠️ 刻意**不设** `setTargetBufferBytes`
        // 文档已记明：设它会让 Media3 按"字节数"反推缓冲时长，
        // **高码率片源反而缓冲更短** ⇒ 起播更慢或更易卡。
        // `setBufferDurationsMs` 才是按**时长**控制起播门槛的正确入口。
        //
        // ## 代价（如实）
        // 网络抖动时会更早开播 ⇒ 可能更早出现"缓冲中"。
        // 但与 mpv 侧同样的道理：那是**真实状态**，比"等满 2.5 秒再卡"好。
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                15_000,   // minBufferMs（稳态下限）
                50_000,   // maxBufferMs（稳态上限，与默认一致）
                1_000,    // ★ bufferForPlaybackMs：起播门槛 2.5s → 1s
                2_000,    // bufferForPlaybackAfterRebufferMs：卡顿恢复
            )
            .build()

        val p = ExoPlayer.Builder(context, renderers)
            .setMediaSourceFactory(sourceFactory)
            .setLoadControl(loadControl)
            .setHandleAudioBecomingNoisy(true) // 拔耳机自动暂停
            .build()
        // ★★ **禁止 Media3 自动选"它自己认为可播"的音轨**
        //
        // ## 真机事故（2026-10-11，《复仇者联盟》）
        // Dart 侧已按内核能力排除 truehd/dts，选了 **AC3**，
        // 但 Media3 仍然自己去选了 `国语 DTS`：
        // ```
        // 10-11 01:29:57.530 CF-Media3: 播放错误: ERROR_CODE_DECODER_INIT_FAILED
        //   MediaCodecAudioRenderer error, index=1,
        //   format=Format(5, 国语, null, audio/vnd.dts, ...),
        //   format_supported=NO_UNSUPPORTED_TYPE
        // ```
        // ⇒ 原因是 **Media3 的 `DefaultTrackSelector` 独立选轨**，
        //   它在 `prepare` 时按自己的偏好（语言/声道数）挑，
        //   **覆盖**我们之前用 `setAudioTrack` 下的 override。
        //
        // ## 为什么 `NO_UNSUPPORTED_TYPE` 会让**整个播放停住**
        // `MediaCodecAudioRenderer` 初始化失败 ⇒ `PlaybackException`
        // ⇒ 画面也是黑的（不是"静音继续"）。用户看到的是"卡在黑屏"。
        //
        // ## 修法：把**音频**轨的选择权完全收归 Dart
        // `setTrackTypeDisabled(AUDIO, false)` 保留音频 + 清 overrides，
        // 但**不启用** Media3 的"自适应选择"；真正的选择由 Dart 通过
        // `setAudioTrack`（`applyOverride`）下达。
        // 初次 `prepare` 前若 Dart 还没下达，则**先禁用音频**，
        // 避免 Media3 抢选一条解不了的（宁可短暂无声，也不要黑屏）。
        p.trackSelectionParameters = p.trackSelectionParameters
            .buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
            .build()
        p.addListener(listener)
        // ★ 渲染器级事件（音频编码是否受支持）走 AnalyticsListener ——
        //   `onAudioInputFormatChanged` 不在 Player.Listener 上（见其注释）
        p.addAnalyticsListener(analyticsListener)
        player = p
        surfaceProducer?.let { p.setVideoSurface(it.surface) }
        return p
    }

    private fun open(url: String) {
        val p = ensurePlayer()
        p.stop()

        // ⚠️ 请求头必须透传：115 网盘的 CDN 直链与取址 UA 强绑定，
        //    且要带 download_token Cookie，两者都不在 URL 里（ADR 0007）。
        //    漏掉 → CDN 403 → 现象是"地址取到了但播不了"。
        val dataSourceFactory = if (currentHeaders.isEmpty()) {
            null
        } else {
            DefaultHttpDataSource.Factory()
                .setAllowCrossProtocolRedirects(true)
                .setConnectTimeoutMs(15_000)
                .setReadTimeoutMs(15_000)
                .setDefaultRequestProperties(currentHeaders)
        }

        if (dataSourceFactory != null) {
            val src = DefaultMediaSourceFactory(
                androidx.media3.datasource.DefaultDataSource.Factory(context, dataSourceFactory)
            )
            p.setMediaSource(src.createMediaSource(mediaItemFor(url)))
        } else {
            p.setMediaItem(mediaItemFor(url))
        }

        // ★★ 起始位置在 **prepare 之前** 设定（起播优化，2026-10-10）
        //
        // ## 为什么必须在这个位置
        // Media3 的 `seekTo()` 在 `prepare()` **之前**调用时会被记录成
        // "起始位置"（`SimpleExoPlayer.startPositionMs` —— 已在 1.4.1
        // 字节码里核实该字段存在）⇒ 播放器**直接从该位置开始缓冲**。
        //
        // 若放在 `prepare()` 之后（原写法：open 完再由 Dart 侧 seek），
        // 播放器会先按 0 位置建立缓冲、再跳转 ⇒ 多一次往返 + 丢掉已缓冲
        // 的片头数据。对 4K 高码率片源是**数秒**的差别。
        //
        // ## ⚠️ 为什么不用 `setStartPosition`
        // 那是 `ExoPlayer.Builder` 的方法，但**本项目的 media3 1.4.1
        // 没有它** —— 已用字节码核实：`ExoPlayer$Builder` 里与 Start
        // 相关的只有 `setMaxSeekToPreviousPositionMs`。
        // ⇒ 用官方一路支持的 `seekTo` + `prepare` 组合（语义等价）。
        //
        // ⚠️ 顺序敏感：这两行**不能**互换 —— `seekTo` 放到 `prepare` 之后
        //    就退化成"先缓冲片头再跳"（等于回到优化前的行为）。
        if (pendingStartMs > 0) {
            p.seekTo(pendingStartMs)
            Log.i(TAG, "open: seekTo(${pendingStartMs}ms) 于 prepare 之前（起播即定位）")
        }
        p.prepare()
        p.playWhenReady = true
        startTicker()
        emitState(force = true)
    }

    private fun releasePlayer() {
        stopTicker()
        player?.let {
            it.setVideoSurface(null)
            it.removeListener(listener)
            it.release()
        }
        player = null
        disposeTexture()
    }

    // ---------------- 轨道选择 ----------------

    private fun selectAudioTrack(id: String?) {
        val p = player ?: return
        val tracks = p.currentTracks
        if (id.isNullOrEmpty() || id == "auto") {
            p.trackSelectionParameters = p.trackSelectionParameters
                .buildUpon()
                .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
                .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, false)
                .build()
            return
        }
        val index = id.toIntOrNull() ?: return
        applyOverride(p, C.TRACK_TYPE_AUDIO, index, tracks)
    }

    private fun selectSubtitleTrack(id: String?) {
        val p = player ?: return
        if (id.isNullOrEmpty() || id == "no" || id == "auto") {
            // "关闭字幕"：Media3 用 setTrackTypeDisabled 表达
            p.trackSelectionParameters = p.trackSelectionParameters
                .buildUpon()
                .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, id == "no")
                .build()
            return
        }
        val index = id.toIntOrNull() ?: return
        applyOverride(p, C.TRACK_TYPE_TEXT, index, p.currentTracks)
    }

    /** 按"该类型的第几条"选择轨道。
     *
     * ## ★★ 真机修的两个 bug（2026-10-11，《复仇者联盟》选轨错位）
     *
     * ### bug 1：**差一位**（`seen` 是 0-based，而上报的 id 是 1-based）
     * `emitTracks` 用 `++audioId` ⇒ 第一条音轨的 id 是 **1**。
     * 而这里 `seen` 从 **0** 开始 ⇒ `seen == index` 命中**第二条**。
     * 结果：Dart 说"选第 5 条（AC3）"，实际选中**第 6 条**。
     *
     * ### bug 2：`format.id` **撞车**（更隐蔽、危害更大）
     * 原实现同时接受 `format.id?.toIntOrNull() == index`。
     * 但 Media3 的 `Format.id` 是**容器自己的轨号**（matroska 的 track number），
     * 与我们的"第几条音轨"**语义完全不同**：
     * ```
     * 真机日志：要求选 id=5（AC3），实际生效
     *   format=Format(5, 国语, null, audio/vnd.dts, ...)
     *   format_supported=NO_UNSUPPORTED_TYPE   ← 选到了 DTS ⇒ 解码失败 ⇒ 黑屏
     * ```
     * ⇒ 两条判据"或"在一起时，`format.id` 会**抢先命中错误的轨**。
     *
     * ## 修法
     * · **只用位置序**（`seen + 1 == index`）——与 `emitTracks` 的编号口径一致
     * · **删掉 `format.id` 判据**（它的语义不是我们发的那个 id）
     */
    private fun applyOverride(
        p: ExoPlayer,
        trackType: Int,
        index: Int,
        tracks: Tracks,
    ) {
        // ★ `seenCounter` / `groupIndex` 跨 group 连续计数
        //   （`emitTracks` 也是"跨所有同类型 group 连续编号"）
        var seenCounter = 1
        var groupIndex = 0
        for (group in tracks.groups) {
            if (group.type != trackType) continue
            // 跨**所有同类型 group** 连续计数（emitTracks 也是这么编的）
            for (i in 0 until group.length) {
                if (seenCounter == index) {
                    p.trackSelectionParameters = p.trackSelectionParameters
                        .buildUpon()
                        .setTrackTypeDisabled(trackType, false)
                        .addOverride(
                            TrackSelectionOverride(group.mediaTrackGroup, i))
                        .build()
                    Log.i(
                        TAG,
                        "选轨 $trackType index=$index → group=$groupIndex " +
                            "track=$i mime=${group.getTrackFormat(i).sampleMimeType}",
                    )
                    return
                }
                seenCounter++
            }
            groupIndex++
        }
        Log.w(TAG, "选轨失败：$trackType index=$index 超出范围（共 $seenCounter 条）")
    }

    // ---------------- 事件上报 ----------------

    private fun emitState(force: Boolean) {
        val p = player ?: return
        val pos = p.currentPosition.coerceAtLeast(0)
        val dur = p.duration.let { if (it == C.TIME_UNSET) 0L else it }
        val playing = p.isPlaying
        val buffering = p.playbackState == Player.STATE_BUFFERING

        if (!force && pos == lastPositionMs && playing == lastPlaying &&
            buffering == lastBuffering && dur == lastDurationMs
        ) {
            return
        }
        lastPositionMs = pos
        lastPlaying = playing
        lastBuffering = buffering
        lastDurationMs = dur

        eventSink?.success(JSONObject().apply {
            put("type", "state")
            put("position", pos)
            put("duration", dur)
            put("buffer", p.bufferedPosition)
            put("playing", playing)
            put("buffering", buffering)
            put("rate", p.playbackParameters.speed.toDouble())
        }.toString())
    }

    /**
     * 上报轨道列表（与 mpv 内核**同一份 JSON 形状**）。
     *
     * ⚠️ 形状必须一致 —— Dart 侧 `_parseTracks` 是共用的，
     * 两者形状不同会让其中一边静默解析出空轨道（"看不到音轨"）。
     * 字段名沿用 mpv 的：`id` / `title` / `lang` / `codec` /
     * `demux-channels` / `ff-index` / `default` / `external` / `forced`。
     */
    private fun emitTracks(tracks: Tracks) {
        val arr = JSONArray()
        var ffIndex = 0
        var audioId = 0
        var subId = 0
        for (group in tracks.groups) {
            val type = when (group.type) {
                C.TRACK_TYPE_AUDIO -> "audio"
                C.TRACK_TYPE_TEXT -> "sub"
                C.TRACK_TYPE_VIDEO -> "video"
                else -> continue
            }
            for (i in 0 until group.length) {
                val fmt = group.getTrackFormat(i)
                val o = JSONObject()
                val id = when (type) {
                    "audio" -> ++audioId
                    "sub" -> ++subId
                    else -> 0
                }
                o.put("type", type)
                o.put("id", id)
                o.put("ff-index", ffIndex)
                o.put("title", fmt.label ?: JSONObject.NULL)
                o.put("lang", fmt.language ?: JSONObject.NULL)
                o.put("codec", codecName(fmt.sampleMimeType))
                o.put("demux-channels", fmt.channelCount)
                o.put("default", group.isSelected && i == 0)
                o.put("external", false)
                o.put("forced", false)
                arr.put(o)
                ffIndex++
            }
        }
        eventSink?.success(JSONObject().apply {
            put("type", "tracks")
            put("data", arr)
        }.toString())
    }

    private fun codecName(mime: String?): String? = when {
        mime == null -> null
        mime.contains("aac") -> "aac"
        mime.contains("eac3") -> "eac3"
        mime.contains("ac3") -> "ac3"
        mime.contains("opus") -> "opus"
        mime.contains("flac") -> "flac"
        mime.contains("dts") -> "dts"
        mime.contains("truehd") -> "truehd"
        mime.contains("avc") || mime == MimeTypes.VIDEO_H264 -> "h264"
        mime.contains("hevc") -> "hevc"
        mime.contains("av1") -> "av1"
        mime.contains("vtt") -> "webvtt"
        mime.contains("subrip") -> "subrip"
        mime.contains("ttml") -> "ttml"
        else -> mime.substringAfterLast('/')
    }
}
