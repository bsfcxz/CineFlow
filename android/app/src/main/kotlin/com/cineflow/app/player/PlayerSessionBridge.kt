package com.cineflow.app.player

import android.os.Bundle
import android.util.Log

/**
 * 播放会话与内核之间的**状态/命令桥**（2026-10-09，K3 / CF-P3-KERNEL-004）。
 *
 * ## ★ 核心设计决策：命令**不**直接操作播放器，而是转发给 Dart
 *
 * 这个类同时被三方使用：两个内核（推状态）+ 会话服务（收命令）。
 * 关键问题是**媒体键按下后由谁执行**，有两条路：
 *
 * | 方案 | 问题 |
 * |---|---|
 * | **A. 会话层直接控制原生播放器** | ❌ **两个主** —— Dart 侧也控制播放器（UI 的播放/暂停按钮、手势、自动连播），两边各自改状态必然**不同步**（通知栏显示"播放中"而实际已暂停） |
 * | **B. 会话层把命令转发给 Dart，由 Dart 走既有控制器** | ✅ **单一事实源** —— 与 UI 点击走**同一条代码路径**，不会出现两套逻辑 |
 *
 * 本项目选 **B**。理由与既有架构一致：`player_providers` 是状态中枢，
 * `PlaybackController` 是唯一的播放控制入口（见 `docs/DUAL-KERNEL.md` §2）。
 * 若会话层自己实现一套"暂停→暂停内核"，那"长按倍速""自动连播"等
 * 复杂逻辑就必须再实现一遍 —— 那正是本项目反复避免的"两套逻辑"。
 *
 * ## 后台播放的能力边界（如实说明）
 * 播放器实例在 **Flutter engine** 里（`PlayerChannel` / `Media3Channel` 由
 * `MainActivity` 创建）。故：
 * · App 切后台、进程存活 ⇒ **能继续播**（前台服务进一步降低被杀概率）
 * · 若进程被系统杀死 ⇒ 播放中断（要真正"独立于 UI 的后台播放"，
 *   得把播放器搬进 Service —— 那是**更大的重构**，不在 K3 范围）
 * 会话层的价值在于：**通知栏控制 + 媒体键 + 音频焦点 + 前台服务防杀**。
 */
class PlayerSessionBridge {

    /** 会话状态快照（由内核推送、由会话读取）。 */
    data class Snapshot(
        val title: String = "",
        val artist: String = "",
        /** 媒体标题（通常是"第 N 集 · 剧名"）。 */
        val subtitle: String = "",
        val artworkUrl: String? = null,
        val durationMs: Long = 0L,
        val positionMs: Long = 0L,
        val isPlaying: Boolean = false,
        val isBuffering: Boolean = false,
        /** 是否已有一部片在放（决定会话是否"活跃"）。 */
        val hasMedia: Boolean = false,
        val speed: Float = 1.0f,
    )

    /** 状态变化通知（会话层订阅，用来刷新通知栏）。 */
    var onStateChanged: ((Snapshot) -> Unit)? = null

    /**
     * 命令回调（会话层 → Dart）。
     *
     * `action` 取值是**稳定契约**（Dart 侧 switch 匹配，勿随意改名）：
     * `play` / `pause` / `playPause` / `next` / `previous` /
     * `seekForward` / `seekBack` / `seekTo` / `stop`
     * —— `seekTo` 的毫秒值在 `args.getLong("positionMs")`。
     */
    var onCommand: ((action: String, args: Bundle?) -> Unit)? = null

    @Volatile
    private var snapshot = Snapshot()

    /** 当前快照（读操作，供服务构建 `Player.State`）。 */
    fun current(): Snapshot = snapshot

    /**
     * 更新快照并通知会话层。
     *
     * ## 为什么合并成一个"整快照"更新而不是逐个字段 setter
     * 逐个 setter 会**多次触发** `onStateChanged`（改标题、改时长、改播放状态
     * 是三条事件），通知栏会闪三次。
     * 整快照更新 + **相同则不通知**（见下）保证每次真实变化只刷一次。
     */
    fun update(
        title: String? = null,
        artist: String? = null,
        subtitle: String? = null,
        artworkUrl: String? = null,
        durationMs: Long? = null,
        positionMs: Long? = null,
        isPlaying: Boolean? = null,
        isBuffering: Boolean? = null,
        hasMedia: Boolean? = null,
        speed: Float? = null,
    ) {
        val next = snapshot.copy(
            title = title ?: snapshot.title,
            artist = artist ?: snapshot.artist,
            subtitle = subtitle ?: snapshot.subtitle,
            artworkUrl = artworkUrl ?: snapshot.artworkUrl,
            durationMs = durationMs ?: snapshot.durationMs,
            positionMs = positionMs ?: snapshot.positionMs,
            isPlaying = isPlaying ?: snapshot.isPlaying,
            isBuffering = isBuffering ?: snapshot.isBuffering,
            hasMedia = hasMedia ?: snapshot.hasMedia,
            speed = speed ?: snapshot.speed,
        )
        // ⚠️ 相同就**不**通知：进度是每秒（甚至更密）推的，
        //    每次都刷通知栏会导致 CPU 白耗 + 通知栏闪烁。
        if (next == snapshot) return
        snapshot = next
        onStateChanged?.invoke(next)
    }

    /**
     * 清空状态（退出播放页 / 内核销毁时调用）。
     *
     * 必须清 —— 否则退出播放器后通知栏还挂着"正在播放某剧"，
     * 点它还会把命令发给一个已销毁的内核。
     */
    fun clear() {
        snapshot = Snapshot()
        onStateChanged?.invoke(snapshot)
    }

    /** 会话命令入口（由 `SimpleBasePlayer` 的 handle* 调用）。 */
    fun dispatch(action: String, args: Bundle? = null) {
        Log.i(TAG, "会话命令: $action ${args?.toString() ?: ""}")
        onCommand?.invoke(action, args)
    }

    private companion object {
        const val TAG = "CineFlowSession"
    }
}
