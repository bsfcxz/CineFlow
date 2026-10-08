package com.cineflow.app.player

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * 音频焦点管理（**自研** —— 见 ADR 0009「音频焦点不代劳」）。
 *
 * ## 为什么必须自己写
 * `media3-session` 提供通知栏/蓝牙键/后台播放的**会话框架**，
 * 但它**不替你申请音频焦点** —— 上游文档与 [androidx/media] 的
 * `SimpleBasePlayer` 说明都明确这一点。
 * 不做焦点的后果是**用户可感知的**：
 * · 来电/微信语音进来时，视频**不停**（和通话声音叠在一起）
 * · 别的 App 开始放音乐，两边**同时响**
 * · 拔耳机时**外放突然出声**（公共场合社死）
 *
 * ## 三种失焦的处理（Android 的标准语义）
 * | 类型 | 场景 | 正确做法 |
 * |---|---|---|
 * | `AUDIOFOCUS_LOSS` | 别的播放器**永久**拿走（如音乐 App 播放） | **暂停**（且不应自动恢复，除非用户手动） |
 * | `AUDIOFOCUS_LOSS_TRANSIENT` | 来电、导航播报（**临时**） | 暂停；拿到焦点后**自动恢复** |
 * | `AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK` | 通知音（可"闪避"） | **不暂停**，把音量压低（duck） |
 *
 * ⚠️ `CAN_DUCK` 与 `TRANSIENT` 的区别最容易被写错：
 * 把 duck 当 transient 处理 → 每来一条通知视频都暂停一下，体验很差；
 * 把 transient 当 duck → 来电时视频不停。
 *
 * ## 为什么用 `AudioFocusRequest`（API 26+）而不是旧的 `requestAudioFocus`
 * 旧接口在 API 26 起被废弃，且**不支持** `AudioAttributes` 与
 * `setWillPauseWhenDucked` 等细粒度控制。本项目 minSdk 24，
 * 故两条路径都要留（见 [request] 的分支）。
 *
 * ## 与 `setHandleAudioBecomingNoisy` 的关系
 * Media3 的 `setHandleAudioBecomingNoisy(true)` 只处理"耳机拔出"，
 * 与焦点是**两件事**：前者是硬件事件，后者是 App 间的协商。
 * 两者都要有，不能互相替代。
 */
class AudioFocusManager(
    context: Context,
    /** 焦点变化回调（由会话层注入，转发给当前播放器）。 */
    private val listener: Listener,
) {

    /** 焦点变化的语义化回调（避免调用方直接依赖 Android 焦点常量）。 */
    interface Listener {
        /** 永久失焦：应暂停，且**不**自动恢复。 */
        fun onPausePermanent()

        /** 临时失焦：暂停，并在 regain 时自动恢复。 */
        fun onPauseTransient()

        /** 可闪避失焦：继续播放但降低音量。 */
        fun onDuck()

        /**
         * 重新获得焦点：恢复音量（duck 过的话）。
         *
         * ⚠️ 这个回调**只负责音量**；「要不要恢复播放」由
         * [onResumeAfterTransient] 单独决定 —— 两者是不同的问题：
         * · 一次通知音（duck）结束后：**只需**恢复音量，播放从没停过
         * · 一次来电（transient）结束后：**既要**恢复音量，**也要**恢复播放
         * 把它们合成一个回调，就会在"只是 duck 过"时误触发播放。
         */
        fun onRegain()

        /**
         * 因**临时**失焦而暂停后，焦点已恢复 ⇒ 可以自动续播。
         *
         * 会话层在此判断"用户是否手动暂停过"：若用户自己按了暂停，
         * **不**应因来电结束而突然开播（这是 Android 的推荐行为）。
         */
        fun onResumeAfterTransient()
    }

    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /** API 26+ 的焦点请求对象（旧版本为 null）。 */
    private var focusRequest: AudioFocusRequest? = null

    /** 当前是否持有焦点（用于避免重复申请）。 */
    private var hasFocus = false

    /**
     * 是否因**临时**失焦而暂停 —— 决定 regain 时要不要自动恢复。
     *
     * 只记 transient（不含 permanent）：永久失焦后即使拿回焦点，
     * 也应等用户主动播放（这是 Android 的推荐行为，也是各大播放器的做法）。
     */
    private var pausedForTransient = false

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        Log.d(TAG, "音频焦点变化: $change")
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                hasFocus = true
                // 先恢复音量（duck 过的话）—— 无论有没有暂停过都要做
                listener.onRegain()
                if (pausedForTransient) {
                    pausedForTransient = false
                    // 再决定要不要续播（由会话层判断用户是否手动暂停过）
                    listener.onResumeAfterTransient()
                }
            }

            AudioManager.AUDIOFOCUS_LOSS -> {
                hasFocus = false
                // 永久失焦：**不**记 pausedForTransient —— 拿回来也不自动播
                listener.onPausePermanent()
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                hasFocus = false
                pausedForTransient = true
                listener.onPauseTransient()
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // 注意：**不失焦**（hasFocus 保持 true）—— 我们只是被要求小声点
                listener.onDuck()
            }
        }
    }

    /**
     * 申请音频焦点。
     *
     * ## 内容类型必须是 `CONTENT_TYPE_MOVIE`
     * 它让系统知道我们在放视频 —— 决定 duck 行为与蓝牙键的路由。
     * 用 `CONTENT_TYPE_MUSIC` 会让"看剧"被当成"听歌"（通知栏图标、焦点优先级都会偏）。
     *
     * ## 用法约束
     * 播放器**开始播放前**调用；`abandon()` 在暂停/退出时调用。
     * 不建议在 `pause()` 时立即 abandon（会在短暂切后台时丢焦点、
     * 回来还得重申请），本项目策略：**暂停不放弃，退出才放弃**。
     *
     * @return 是否成功拿到焦点（false 时理论上不该播放，但实践中
     *   多数 App 仍会播放 —— 因为部分 ROM 返回值不可靠。本项目选择
     *   **照常播放但记日志**，避免"点了没反应"这种更糟的体验）。
     */
    fun request(): Boolean {
        if (hasFocus) return true

        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                .build()
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attrs)
                // 允许系统在"可闪避"场景让我们 duck（而不是直接抢走焦点）
                .setWillPauseWhenDucked(false)
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            focusRequest = req
            audioManager.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            )
        }

        hasFocus = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        if (!hasFocus) {
            // ⚠️ 部分 ROM（尤其 MIUI）在**没有其他播放器**时也可能返回 FAILED。
            //    这里只记日志、**不阻止播放** —— 否则用户会遇到"点播放没反应"，
            //    那比"可能的焦点冲突"严重得多。
            Log.w(TAG, "音频焦点申请被拒（code=$result），仍继续播放")
        }
        return hasFocus
    }

    /**
     * 放弃音频焦点（退出播放器时调用）。
     *
     * ⚠️ 必须先判断 `hasFocus` 再 abandon：某些 ROM 上重复 abandon
     * 会抛 `IllegalStateException`（API 26+ 的 `AudioFocusRequest` 契约）。
     */
    fun abandon() {
        if (!hasFocus) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusListener)
        }
        hasFocus = false
        pausedForTransient = false
        Log.d(TAG, "已放弃音频焦点")
    }

    private companion object {
        const val TAG = "CineFlowAudio"
    }
}
