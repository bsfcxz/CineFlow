package com.cineflow.app.system

import android.app.Activity
import android.content.Context
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/**
 * 播放器需要的**系统能力**通道（亮度 / 音量 / 唤醒锁）。
 *
 * ## 为什么自己写而不是引插件
 * 这三件事在 Android 上各只需十几行系统 API：
 *   · 亮度 → `WindowManager.LayoutParams.screenBrightness`
 *   · 音量 → `AudioManager.STREAM_MUSIC`
 *   · 唤醒锁 → `WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON`
 *
 * 而对应的 Flutter 插件（`screen_brightness` / `volume_controller` /
 * `wakelock_plus`）会各带来一棵依赖树。本项目已因 `media_kit`
 * 的依赖树吃过亏（ADR 0009 把它换成了自持 libmpv），
 * 故这三项**自己实现**，只保留 `screen_brightness` 作为可选依赖
 * （它已在 pubspec 里，用于系统级亮度记忆）。
 *
 * ## 统一单位：0–100
 * 三处 API 的原生单位各不相同：
 *   · 亮度：`screenBrightness` 是 0.0–1.0 的浮点
 *   · 音量：`getStreamVolume` 是**整数档位**（最大值随设备不同，常见 15）
 *   · Dart 侧手势/面板：0–100
 * 全部在**本文件内**换算成 0–100 对外，避免"这层 0–1、那层 0–100"
 * （这类单位错误不会报错，只会表现成"拖到底了没反应"）。
 */
class SystemChannel(private val activity: Activity) {

    companion object {
        const val BRIGHTNESS = "com.cineflow.app/brightness"
        const val VOLUME = "com.cineflow.app/volume"
        const val WAKELOCK = "com.cineflow.app/wakelock"

        /** 通知权限（K3 媒体会话用）。 */
        const val NOTIFICATION = "com.cineflow.app/notification"

        /** `POST_NOTIFICATIONS` 的请求码（取值任意，只需唯一）。 */
        private const val REQ_POST_NOTIFICATIONS = 0x0F01

        /**
         * **API 33+ 起 `POST_NOTIFICATIONS` 是运行时权限。**
         *
         * 只在 manifest 声明**不够** —— 用户不授权时通知栏**完全不显示**
         * 媒体控制，而且**不报错**（只有系统日志一行），极难排查。
         * 这正是本项目反复踩的"配了没生效"类型。
         */
        const val PERM_POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS"
    }

    /**
     * 申请通知权限（**必须在 Activity 前台时调**，否则系统直接拒绝且不弹窗）。
     *
     * @return 是否**已经**有此权限（true = 无需弹窗）。
     *   注意：返回 false 只表示"已发起申请"，用户可能拒绝 ——
     *   真正的结果要看下次 `hasNotificationPermission()`。
     */
    fun requestNotificationPermission(): Boolean {
        if (hasNotificationPermission()) return true
        // API < 33 无需申请（那时没有这个权限）
        if (android.os.Build.VERSION.SDK_INT < 33) return true
        activity.requestPermissions(arrayOf(PERM_POST_NOTIFICATIONS),
            REQ_POST_NOTIFICATIONS)
        return false
    }

    /** 当前是否已有通知权限。 */
    fun hasNotificationPermission(): Boolean {
        if (android.os.Build.VERSION.SDK_INT < 33) return true
        return activity.checkSelfPermission(PERM_POST_NOTIFICATIONS) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    fun register(flutterEngine: FlutterEngine) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // ---------------- 亮度 ----------------
        //
        // ⚠️ 只改**当前窗口**的亮度（`window.attributes.screenBrightness`），
        //    不改系统设置。理由：
        //      · 系统设置需要 WRITE_SETTINGS 权限（用户要去设置页手动授权）
        //      · 改系统设置会影响整个手机，退出播放器还得记得改回来
        //    窗口级亮度随 Activity 消失而失效，**无需恢复**，更安全。
        //
        //    取值为 -1（跟随系统）或 0.0–1.0。我们对外用 0–100，
        //    故 0 会被映射成 0.01（完全 0 在部分设备上会黑屏到看不出内容）。
        MethodChannel(messenger, BRIGHTNESS).setMethodCallHandler { call, result ->
            when (call.method) {
                "get" -> {
                    val cur = activity.window.attributes.screenBrightness
                    // -1 表示"跟随系统"：此时读系统默认值作为起点
                    val v = if (cur < 0f) {
                        android.provider.Settings.System.getInt(
                            activity.contentResolver,
                            android.provider.Settings.System.SCREEN_BRIGHTNESS,
                            128,
                        ) / 255f * 100f
                    } else {
                        cur * 100f
                    }
                    result.success(v.coerceIn(0f, 100f).toDouble())
                }
                "set" -> {
                    val raw = call.argument<Double>("value") ?: 50.0
                    val v = (raw.coerceIn(0.0, 100.0) / 100.0).toFloat()
                    val lp = activity.window.attributes
                    lp.screenBrightness = v.coerceAtLeast(0.01f)
                    activity.window.attributes = lp
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ---------------- 音量 ----------------
        //
        // ⚠️ 用 `STREAM_MUSIC`（媒体流），不是 `STREAM_SYSTEM`（提示音）。
        //    后者调了听不到变化，是常见错误。
        //
        // `getStreamVolume` 返回**档位整数**，最大值随设备不同（常见 15），
        // 故必须除以 `getStreamMaxVolume` 归一到 0–100。
        val audio = activity.getSystemService(Context.AUDIO_SERVICE)
                as android.media.AudioManager
        MethodChannel(messenger, VOLUME).setMethodCallHandler { call, result ->
            when (call.method) {
                "get" -> {
                    val max = audio.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                    val cur = audio.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
                    result.success(if (max <= 0) 0.0 else cur.toDouble() / max * 100.0)
                }
                "set" -> {
                    val raw = call.argument<Double>("value") ?: 70.0
                    val max = audio.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                    val index = (raw.coerceIn(0.0, 100.0) / 100.0 * max).roundToInt()
                    // FLAG 用 0：不要弹系统音量条（我们自己画了指示器，
                    // 两套同时出现会重叠）
                    audio.setStreamVolume(
                        android.media.AudioManager.STREAM_MUSIC,
                        index.coerceIn(0, max),
                        0,
                    )
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ---------------- 唤醒锁 ----------------
        //
        // `FLAG_KEEP_SCREEN_ON`：播放中不熄屏。
        // 用窗口 flag 而不是 `PowerManager.WakeLock`：后者需要
        // WAKE_LOCK 权限且**忘记释放会持续耗电**（本项目明确避免这类风险），
        // 而窗口 flag 随 Activity 销毁自动失效。
        MethodChannel(messenger, WAKELOCK).setMethodCallHandler { call, result ->
            when (call.method) {
                "enable" -> {
                    activity.runOnUiThread {
                        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }
                "disable" -> {
                    activity.runOnUiThread {
                        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ---------------- 通知权限（K3 媒体会话）----------------
        //
        // ## 为什么单独一个通道而不塞进会话通道
        // 权限请求**必须由 Activity 发起**（`requestPermissions`），
        // 而 `SystemChannel` 正是持有 Activity 的那个类；
        // `SessionChannel` 只有 Context。放这里职责也更清楚。
        MethodChannel(messenger, NOTIFICATION).setMethodCallHandler { call, result ->
            when (call.method) {
                "has" -> result.success(hasNotificationPermission())
                // 必须在主线程请求（系统弹窗要求）
                "request" -> {
                    activity.runOnUiThread { requestNotificationPermission() }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
