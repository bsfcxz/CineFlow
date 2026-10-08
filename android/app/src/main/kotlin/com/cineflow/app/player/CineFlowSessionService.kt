package com.cineflow.app.player

import android.app.PendingIntent
import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * 媒体会话服务（K3 / CF-P3-KERNEL-004，2026-10-09）。
 *
 * ## 它解决什么（四个问题一次解决）
 * | 能力 | 靠什么 |
 * |---|---|
 * | **通知栏控制**（播放/暂停/快进/封面） | `MediaSession` + 会话层自带的 `MediaNotification` |
 * | **蓝牙 / 有线耳机键** | `MediaSession`（系统按会话路由媒体键，**不要求 App 聚焦**） |
 * | **后台播放** | 前台服务（`MediaSessionService` 自带 `startForeground`） |
 * | **音频焦点** | **自研** [AudioFocusManager]（Media3 不代劳，见其注释） |
 *
 * ## 为什么用 `MediaSessionService` 而不是自己写前台服务
 * 手写要自己处理：通知渠道、`MediaStyle`、媒体键 `BroadcastReceiver`、
 * API 33+ 的 `FOREGROUND_SERVICE_MEDIA_PLAYBACK` 类型、通知权限……
 * 这些正是 `MediaSessionService` 已经做好的（且跟随系统样式更新）。
 *
 * ## 与 `PlayerChannel` / `Media3Channel` 的关系
 * ```
 *   媒体键/通知栏
 *        ↓  (MediaSession 命令)
 *   CineFlowSessionPlayer  ← 只读状态、只转发命令
 *        ↓ PlayerSessionBridge
 *   Dart 侧 PlaybackController（**唯一**的播放控制入口）
 *        ↓ MethodChannel
 *   两个内核（mpv / Media3）—— 与 UI 点击走**同一条**路径
 * ```
 * 会话层**不直接操作内核** —— 否则会出现"两个主"（见
 * [PlayerSessionBridge] 的说明）。
 *
 * ## ⚠️ 已知边界（如实说明，不夸大）
 * 播放器实例在 **Flutter engine** 里（`MainActivity` → `PlayerChannel`）。
 * 故本服务的"后台播放"= **App 在后台、进程存活时继续播 + 降低被杀概率**。
 * **不包含**"进程被杀后仍能播"—— 那需要把播放器搬进 Service，
 * 属更大的重构（超出 K3 范围）。
 */
@UnstableApi
class CineFlowSessionService : MediaSessionService() {

    private var mediaSession: MediaSession? = null

    /** 音频焦点管理（自研，见其注释）。 */
    private var audioFocus: AudioFocusManager? = null

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "会话服务创建")

        val bridge = PlayerSessionRegistry.bridge

        // 会话播放器：把自有内核包装成 Media3 的 Player
        val sessionPlayer = CineFlowSessionPlayer(bridge)

        val session = MediaSession.Builder(this, sessionPlayer)
            .setCallback(SessionCallback())
            .build()
        mediaSession = session

        // ---- ★ 把会话注册进通知管理器（2026-10-09，真机排查得出）----
        //
        // ## 为什么必须显式调（这是通知不贴的真正原因）
        // `MediaSession.Builder(...).build()` **只创建**会话，并**不会**
        // 把它纳入通知管理。字节码取证：
        // ```
        // MediaSessionService.addSession(MediaSession)      ← 注册入口
        // MediaNotificationManager.shouldShowNotification(MediaSession)
        // MediaNotificationManager.startForeground(...)     ← 贴通知
        // ```
        // 而 `addSession` 只由 `onStartCommand`（携带特定 intent 时）
        // 或**显式调用**触发。我们两条都没走 ⇒ 通知永不出现。
        //
        // ## 真机观测完全吻合这个推断
        // · `dumpsys media_session` 有我们的会话，媒体键可用 ✅
        //   （媒体键走 MediaButton 路径，与通知无关）
        // · 但 `onUpdateNotification` **从不被调用**、
        //   `startForegroundCount=0`、无 NotificationRecord ❌
        //
        // ## 排查代价（值得记下）
        // 为定位它，逐段加了日志验证：
        // Dart 推送到达 ✅ → onStateChanged 触发 ✅ → invalidateState ✅
        // → getState() 每秒被调 ✅ → 但通知链不动
        // ⇒ 才定位到"会话没注册进通知管理器"。
        // **关键教训**：`active=true` 与"能贴通知"是两回事。
        addSession(session)

        // ---- 音频焦点（自研）----
        //
        // 焦点变化 → 通过 bridge 转发给 Dart（**不直接操作内核**，见类注释）。
        audioFocus = AudioFocusManager(this, object : AudioFocusManager.Listener {
            override fun onPausePermanent() {
                // 永久失焦（别的播放器接管）：暂停，且**不**自动恢复
                bridge.dispatch("pause")
            }

            override fun onPauseTransient() {
                // 临时失焦（来电/导航）：暂停，焦点回来后自动续播。
                //
                // ⚠️ 用**专用** action（不是通用的 `pause`）：Dart 侧据此
                //    区分"系统造成的暂停"与"用户按的暂停"——
                //    用户自己暂停的，不该被来电结束触发开播。
                bridge.dispatch("pauseByFocusLoss")
            }

            override fun onDuck() {
                // 可闪避（通知音）：**不暂停**，交给 Dart 侧压低音量。
                // duck 比暂停体验好 —— 用户不会因为一条通知就中断观看。
                bridge.dispatch("duck")
            }

            override fun onRegain() {
                bridge.dispatch("unduck")
            }

            override fun onResumeAfterTransient() {
                // ⚠️ 恢复播放的**判断权在 Dart**：若用户是**自己**按的暂停，
                //    来电结束后不该突然开播（这是 Android 的推荐行为）。
                //    Dart 侧据此区分"因失焦暂停"与"用户暂停"。
                bridge.dispatch("resumeAfterFocusGain")
            }
        })

        // 会话命令 → Dart（媒体键、通知栏按钮都从这里来）
        bridge.onCommand = { action, args ->
            PlayerSessionRegistry.commandSink?.invoke(action, args)
        }

        // ---- ★ 音频焦点：在"真的开始出声"时申请 ----
        //
        // ## 为什么不能只在 onPlaybackResumption 里申请（真机踩过）
        // 那个回调只在"系统要求恢复播放"（蓝牙重连等）时触发，
        // **正常起播根本不走它** ⇒ 焦点从未被申请
        // （真机 `dumpsys audio` 里查不到本 App，已被验证脚本抓到）。
        //
        // ## 为什么监听 bridge 而不是 Player
        // `SimpleBasePlayer` **没有**"播放开始"回调
        //（`handleSetPlayWhenReady` 是**命令**不是状态）。
        // 而 bridge 的快照是 Dart 推来的真实状态 ⇒ `isPlaying` 变 true
        // 正是"开始出声"的时刻。
        //
        // ## 为什么在**变为 true** 时申请（而不是每次 update）
        // `request()` 内部有 `hasFocus` 短路，但每次都调仍会走一遍 binder；
        // 且"暂停时申请焦点"会在用户还没看时平白抢走别的 App 的焦点。
        var lastPlaying = false
        val prevHook = bridge.onStateChanged
        bridge.onStateChanged = { snap ->   // hook 链
            prevHook?.invoke(snap)
            if (snap.isPlaying && !lastPlaying) {
                audioFocus?.request()
            }
            lastPlaying = snap.isPlaying
        }
    }

    /**
     * 系统要会话时返回它。
     *
     * ⚠️ 返回 null 会让系统把本 App 当成"无媒体会话"，
     * 媒体键与通知栏会全部失效（且不报错，极难排查）。
     */
    override fun onGetSession(
        controllerInfo: MediaSession.ControllerInfo,
    ): MediaSession? = mediaSession

    /**
     * App 被划掉时的处理。
     *
     * ⚠️ **不能**在这里 `stopSelf()` 或释放播放器 —— 那会让"划掉 App 后
     * 音乐/视频继续播"失败。本项目选择让服务随会话结束（媒体播完/
     * 用户退出播放页）自然停止，由 Dart 侧显式调 `stopSelf`。
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "任务被移除（播放由 Dart 侧决定是否继续）")
        super.onTaskRemoved(rootIntent)
    }

    /**
     * ★ 贴/撤通知的入口（**诊断用覆盖**）。
     *
     * ## 为什么覆盖它
     * `MediaSessionService` 是否真的尝试贴通知，只有覆盖这个方法才看得见。
     * 不加时只能看到"没有通知"这个结果，无法区分：
     * · 根本没调用（会话状态不满足条件）
     * · 调用了但失败（如通知渠道建不出来）
     *
     * ⚠️ `startForeground` 只应在**播放中**发生；
     *    Media3 内部按 `player.isPlaying` 决定，这里的日志用于确认。
     */
    override fun onUpdateNotification(session: MediaSession, startInForegroundRequired: Boolean) {
        // ⚠️ **只在失败时**打日志（`Log.e`），成功不打：
        //    这个方法每次状态变化都会被调（播放中每秒多次），
        //    成功也打日志会刷屏。
        //
        // ## 为什么值得保留这个覆盖
        // "通知贴不出来"是**完全不报错**的一类故障（真机排查花了好几轮）。
        // 有这一层，失败时至少留下痕迹；成功时零开销。
        try {
            super.onUpdateNotification(session, startInForegroundRequired)
        } catch (e: Throwable) {
            // 贴通知失败**不能**让播放崩溃 —— 但必须留下痕迹
            Log.e(TAG, "onUpdateNotification 失败（通知栏可能不显示）", e)
        }
    }

    override fun onDestroy() {
        Log.i(TAG, "会话服务销毁")
        audioFocus?.abandon()
        audioFocus = null
        // 先移出通知管理器再释放（顺序反了会留下悬挂引用）
        mediaSession?.let { runCatching { removeSession(it) } }
        mediaSession?.release()
        mediaSession = null
        PlayerSessionRegistry.commandSink = null
        super.onDestroy()
    }

    /**
     * 会话回调：这里是我们**主动申请音频焦点**的地方。
     *
     * ## 为什么在 `onPlaybackResumption`/`onPlay` 附近申请
     * 焦点要在"真要出声"时申请 —— 在 `onCreate` 就申请会**平白抢走**
     * 别的 App 的焦点（用户还没点播放）。
     * Media3 没有"播放开始时"的单一回调，故用以下两个时机：
     * · `onPlaybackResumption`：系统要求恢复播放（如蓝牙重连）
     * · 状态变化为 playing：见 `CineFlowSessionPlayer` 的
     *   `handleSetPlayWhenReady`
     */
    private inner class SessionCallback : MediaSession.Callback {

        override fun onConnect(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
        ): MediaSession.ConnectionResult {
            // 允许系统与其他 App 控制（通知栏/蓝牙/手表/车机都靠它）
            return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                .setAvailableSessionCommands(
                    MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS,
                )
                .build()
        }

        override fun onPlaybackResumption(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
        ): com.google.common.util.concurrent.ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            // 申请焦点（恢复播放意味着马上要出声）
            audioFocus?.request()
            // 本项目不做"断点续播恢复"（那是 Emby 服务端会话的职责），
            // 故返回空列表 —— 交由 Dart 侧决定播什么。
            return com.google.common.util.concurrent.Futures.immediateFuture(
                MediaSession.MediaItemsWithStartPosition(
                    emptyList(),
                    0,
                    C.TIME_UNSET,
                ),
            )
        }
    }

    private companion object {
        const val TAG = "CineFlowSession"
    }
}

/**
 * 会话服务的**全局注册表**（单例）。
 *
 * ## 为什么需要它
 * 服务由系统创建（`onCreate` 时机不可控），而 `MainActivity` 需要在
 * **Flutter 侧注册内核时**就拿到同一个 bridge（用来推状态、收命令）。
 * 用一个进程内的单例把两边接起来，比让 Activity 去 `bindService`
 * 更简单可靠（且不引入绑定生命周期问题）。
 *
 * ⚠️ **进程内单例**在"服务与 Activity 同进程"时成立 ——
 * 本 App 没给服务配 `android:process`，故成立。
 */
object PlayerSessionRegistry {

    /** 双内核共用的状态/命令桥。 */
    val bridge = PlayerSessionBridge()

    /**
     * 命令出口（由 `PlayerChannel`/`Media3Channel` 注册，
     * 把会话命令转发到 Dart）。
     */
    var commandSink: ((action: String, args: Bundle?) -> Unit)? = null
}
