package com.cineflow.app.player

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.util.UnstableApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 媒体会话通道（K3 / CF-P3-KERNEL-004，2026-10-09）。
 *
 * ## 职责（**双向**，与其它通道"只被 Flutter 调用"不同）
 * | 方向 | 内容 |
 * |---|---|
 * | **原生 → Dart** | 媒体键 / 通知栏按钮触发的命令（`play`/`pause`/`next`/`seekTo`…）|
 * | **Dart → 原生** | ① 推状态（标题/时长/播放中）→ 刷新通知栏<br>② 启动/停止会话服务 |
 *
 * ## 为什么只做"转发"，不在 Kotlin 解析状态
 * 播放状态本来就由 Dart 解析（两个内核的 EventChannel 都发 JSON →
 * Dart 的 `KernelState`）。若在 Kotlin 再解析一遍，就会有**两份解析逻辑**：
 * 内核加字段时只有一处会更新，通知栏便会显示错误信息。
 * ⇒ Kotlin 只**透传** Dart 算好的最终值（"标题显示什么"由 Dart 决定）。
 *
 * ## 命令为什么回 Dart 执行（而不是直接调内核）
 * Dart 的 `PlaybackController` 是**唯一**的播放控制入口（UI 点击/手势/
 * 自动连播都走它）。媒体键若绕过它直接调内核，就会出现"两个主"：
 * 通知栏显示播放中而实际已暂停、自动连播被绕开。
 * 详见 [PlayerSessionBridge] 的说明。
 */
@UnstableApi
class SessionChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val methodChannel = MethodChannel(messenger, METHOD)

    /** 服务是否已启动（避免重复 startService）。 */
    private var serviceStarted = false

    fun register() {
        methodChannel.setMethodCallHandler(this)

        // 会话命令 → Dart（媒体键 / 通知栏按钮）
        //
        // ⚠️ 必须切主线程：命令来自系统（Binder 线程），
        //    而 `MethodChannel.invokeMethod` 要求在主线程调用。
        PlayerSessionRegistry.commandSink = { action, args ->
            mainHandler.post {
                methodChannel.invokeMethod(
                    "onSessionCommand",
                    mapOf(
                        "action" to action,
                        "positionMs" to (args?.getLong(ARG_POSITION_MS) ?: -1L),
                        "speed" to (args?.getFloat(ARG_SPEED) ?: 1.0f),
                    ),
                )
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            /**
             * Dart 推状态 → bridge → 会话（通知栏据此刷新）。
             *
             * 传 null 表示"该字段本次无变化"（`update` 内部保持原值），
             * 免得 Dart 每次都要算全量。
             */
            "updateState" -> {
                PlayerSessionRegistry.bridge.update(
                    title = call.argument<String>("title"),
                    artist = call.argument<String>("artist"),
                    subtitle = call.argument<String>("subtitle"),
                    artworkUrl = call.argument<String>("artworkUrl"),
                    durationMs = call.argument<Number>("durationMs")?.toLong(),
                    positionMs = call.argument<Number>("positionMs")?.toLong(),
                    isPlaying = call.argument<Boolean>("isPlaying"),
                    isBuffering = call.argument<Boolean>("isBuffering"),
                    hasMedia = call.argument<Boolean>("hasMedia"),
                    speed = call.argument<Number>("speed")?.toFloat(),
                )
                result.success(true)
            }

            /** 清空会话状态（退出播放页）。 */
            "clearState" -> {
                PlayerSessionRegistry.bridge.clear()
                result.success(true)
            }

            /**
             * 启动会话服务（**起播时调**）。
             *
             * ## 为什么必须显式启动
             * `MediaSessionService.onCreate` 只在本服务被 `startService`
             * 或 `bindService` 时执行。不启动它 ⇒ **没有 MediaSession** ⇒
             * 通知栏与媒体键全都静默失效（不报错，只在 logcat 有一行）。
             *
             * `startForegroundService` 而非 `startService`：API 26+ 上
             * 后台启动的普通服务会被系统限制；且**播放中就该是前台服务**
             * （既防杀，也让系统按媒体场景对待我们）。
             */
            "start" -> {
                if (!serviceStarted) {
                    try {
                        val intent = Intent(context, CineFlowSessionService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            context.startForegroundService(intent)
                        } else {
                            context.startService(intent)
                        }
                        serviceStarted = true
                        Log.i(TAG, "会话服务已启动")
                    } catch (e: Exception) {
                        // 如实报错，不假装成功 —— 否则 Dart 侧以为会话可用
                        Log.e(TAG, "会话服务启动失败", e)
                        result.error("session_start_failed", e.message, null)
                        return
                    }
                }
                result.success(true)
            }

            /** 停止会话服务（退出播放页）。 */
            "stop" -> {
                if (serviceStarted) {
                    context.stopService(
                        Intent(context, CineFlowSessionService::class.java),
                    )
                    serviceStarted = false
                    Log.i(TAG, "会话服务已停止")
                }
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    companion object {
        const val METHOD = "cineflow/session"
        private const val TAG = "CineFlowSession"
        private const val ARG_POSITION_MS = "positionMs"
        private const val ARG_SPEED = "speed"
    }
}
