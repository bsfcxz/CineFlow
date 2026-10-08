package com.cineflow.app.player

import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/**
 * 把**自有播放器**（mpv / Media3 双内核）包装成 Media3 的 `Player`，
 * 从而接入 `MediaSessionService`（2026-10-09，K3 / CF-P3-KERNEL-004）。
 *
 * ## 为什么用 `SimpleBasePlayer` 而不是实现整个 `Player` 接口
 * `Player` 有 **100+ 个方法**（`BasePlayer` 也不遑多让），逐个实现既冗长又易错。
 * `SimpleBasePlayer` 的设计是「**只实现 `getState()`，其余由基类处理**」：
 * 基类根据 `State` 里的字段自动推导 `isPlaying`/`getDuration`/`getCurrentPosition`
 * 等派生方法，并把 `play()`/`pause()`/`seekTo()` 等命令转成 `handle*` 回调。
 *
 * ⇒ 我们只需提供**状态**与**命令处理**两件事，其余交给基类。
 *
 * ## ★ 命令不直接操作内核（见 [PlayerSessionBridge] 的说明）
 * 所有 `handle*` 都转发给 [PlayerSessionBridge.dispatch]，由它送达 **Dart**，
 * 再走 Dart 侧既有的 `PlaybackController`。
 *
 * **为什么**：Dart 侧是状态中枢（UI 按钮、手势、自动连播都走它）。
 * 若这里直接调内核的暂停，就会出现"两个主"——
 * 通知栏显示播放中而实际已暂停、或自动连播被绕开。
 *
 * ## 状态来源
 * 两个内核在状态变化时调 [bridge].update(...)（见 `PlayerChannel` /
 * `Media3Channel` 的接线），本类只**读**快照。
 * 故内核切换时这里**无需任何改动** —— 这正是用 bridge 解耦的目的。
 */
@UnstableApi
class CineFlowSessionPlayer(
    private val bridge: PlayerSessionBridge,
) : SimpleBasePlayer(android.os.Looper.getMainLooper()) {

    init {
        // 状态一变就 invalidateState() ⇒ 基类重新调 getState() ⇒ 通知栏刷新。
        // 这是 SimpleBasePlayer 的既定用法（不调的话通知栏永远停在第一帧）。
        // 状态一变就 invalidateState() ⇒ 基类重算 getState() ⇒ 通知栏刷新。
        // 这是 SimpleBasePlayer 的既定用法（不调则通知栏永远停在第一帧）。
        bridge.onStateChanged = { invalidateState() }
    }

    /**
     * 唯一的抽象方法：把 [PlayerSessionBridge] 的快照映射成 Media3 的 State。
     *
     * ## 字段映射的要点
     * · `setPlaybackState` 必须给 `STATE_READY` 才能播 ——
     *   给 `STATE_IDLE` 时 `play()` 会被当成"没准备好"而无效果。
     *   本项目在 `hasMedia` 为真时即视为 READY（缓冲中用 `setIsLoading` 表达）。
     * · `setContentPositionMs` 是**当前位置**；`setContentDurationMs` 是**总时长**。
     *   两者缺一，通知栏进度条就不会动。
     * · `setAvailableCommands` 决定**哪些按钮可见**：声明了才有对应按钮，
     *   多声明会让用户看到一个点了没反应的按钮（本项目明确禁止，见 AGENTS §5.8）。
     */
    override fun getState(): State {
        // ⚠️ 这里**不要**打日志：`getState()` 在播放中**每秒被调多次**
        //（每次 `invalidateState()` 都会调），打日志会刷屏且耗电。
        // 排查期间曾临时加过，定位完即移除。
        val s = bridge.current()
        val duration = s.durationMs

        return State.Builder()
            .setAvailableCommands(
                // ⚠️ 只声明**真正实现**的命令。多声明 = 通知栏出现点了没反应的按钮。
                Player.Commands.Builder()
                    .addAll(
                        Player.COMMAND_PLAY_PAUSE,
                        Player.COMMAND_STOP,
                        Player.COMMAND_SEEK_TO_NEXT,
                        Player.COMMAND_SEEK_TO_PREVIOUS,
                        Player.COMMAND_SEEK_BACK,
                        Player.COMMAND_SEEK_FORWARD,
                        Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                        Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
                        Player.COMMAND_GET_TIMELINE,
                        Player.COMMAND_GET_METADATA,
                    )
                    .build(),
            )
            // 有媒体且内核报"在放" ⇒ READY；否则 IDLE（此时 play() 无意义）
            .setPlaybackState(
                if (s.hasMedia) Player.STATE_READY else Player.STATE_IDLE,
            )
            // ⚠️ 第二个参数是**播放抑制原因**（PlaybackSuppressionReason），
            //    不是可选的：签名是 `setPlayWhenReady(boolean, int)`。
            //    传 `NONE`（无抑制）—— 若传 `TRANSIENT_AUDIO_FOCUS_LOSS`，
            //    系统会以为我们因失焦而暂停，可能影响媒体键行为。
            .setPlayWhenReady(s.isPlaying, Player.PLAYBACK_SUPPRESSION_REASON_NONE)
            .setIsLoading(s.isBuffering)
            .setPlaylist(
                listOf(
                    MediaItemData.Builder(MEDIA_ID)
                        .setMediaItem(
                            MediaItem.Builder()
                                .setMediaId(MEDIA_ID)
                                .setMediaMetadata(
                                    MediaMetadata.Builder()
                                        .setTitle(s.title.ifEmpty { null })
                                        .setArtist(s.subtitle.ifEmpty { s.artist.ifEmpty { null } })
                                        .setArtworkUri(
                                            s.artworkUrl?.let { android.net.Uri.parse(it) },
                                        )
                                        .setIsPlayable(true)
                                        .build(),
                                )
                                .build(),
                        )
                        .setDurationUs(
                            // 单位是**微秒**；时长未知时用 C.TIME_UNSET
                            if (duration > 0) duration * 1000 else C_TIME_UNSET,
                        )
                        .build(),
                ),
            )
            .setCurrentMediaItemIndex(0)
            .setContentPositionMs(s.positionMs)
            // 跳转步长：通知栏/媒体键的"快进 10 秒"用它（与 Dart 侧手势一致）
            .setSeekBackIncrementMs(SEEK_INCREMENT_MS)
            .setSeekForwardIncrementMs(SEEK_INCREMENT_MS)
            .setPlaybackParameters(
                androidx.media3.common.PlaybackParameters(s.speed),
            )
            .build()
    }

    // ---------------- 命令处理（全部转发给 Dart，见类注释）----------------

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        bridge.dispatch(if (playWhenReady) ACTION_PLAY else ACTION_PAUSE)
        return Futures.immediateVoidFuture()
    }

    override fun handlePrepare(): ListenableFuture<*> =
        // 我们的内核在 open() 时就已准备，无需单独 prepare
        Futures.immediateVoidFuture()

    override fun handleStop(): ListenableFuture<*> {
        bridge.dispatch(ACTION_STOP)
        return Futures.immediateVoidFuture()
    }

    override fun handleRelease(): ListenableFuture<*> {
        // ⚠️ **不**在这里释放内核：会话的 release 可能因"切后台"触发，
        //    而播放要继续（这正是 K3 的目的之一）。
        //    内核生命周期由 Dart 侧的播放页负责（它知道用户是否真的退出）。
        bridge.onStateChanged = null
        return Futures.immediateVoidFuture()
    }

    override fun handleSeek(
        mediaItemIndex: Int,
        positionMs: Long,
        seekCommand: Int,
    ): ListenableFuture<*> {
        bridge.dispatch(
            ACTION_SEEK_TO,
            Bundle().apply { putLong(ARG_POSITION_MS, positionMs) },
        )
        return Futures.immediateVoidFuture()
    }

    override fun handleSetPlaybackParameters(
        playbackParameters: androidx.media3.common.PlaybackParameters,
    ): ListenableFuture<*> {
        // 倍速也走 Dart（它才是"用户倍速"的唯一事实源 —— 见长按倍速的 5 条禁令）
        bridge.dispatch(
            ACTION_SET_SPEED,
            Bundle().apply { putFloat(ARG_SPEED, playbackParameters.speed) },
        )
        return Futures.immediateVoidFuture()
    }

    private companion object {
        /** 单曲会话：本 App 一次只放一集，播放列表由 Dart 侧管理。 */
        const val MEDIA_ID = "cineflow-current"

        const val SEEK_INCREMENT_MS = 10_000L

        /** `C.TIME_UNSET`（避免为它多引一个类）。 */
        const val C_TIME_UNSET = Long.MIN_VALUE + 1

        const val ACTION_PLAY = "play"
        const val ACTION_PAUSE = "pause"
        const val ACTION_STOP = "stop"
        const val ACTION_SEEK_TO = "seekTo"
        const val ACTION_SET_SPEED = "setSpeed"

        const val ARG_POSITION_MS = "positionMs"
        const val ARG_SPEED = "speed"
    }
}
