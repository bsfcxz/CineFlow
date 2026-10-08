package com.cineflow.app

import com.cineflow.app.player.Media3Channel
import com.cineflow.app.player.PlayerChannel
import com.cineflow.app.player.SessionChannel
import com.cineflow.app.system.SystemChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 播放内核 1/2：原生 mpv（自持 libmpv.so + Kotlin/JNI 薄桥，Flutter 纹理输出）。
        // 格式支持最全，且支持画面滤镜与音视频延迟。
        PlayerChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer,
        ).register()

        // 播放内核 2/2：Media3（androidx.media3 / ExoPlayer）。
        // 与 Android 系统媒体框架同源，便于后续接媒体会话/蓝牙键/音频焦点。
        // 输出方式与 mpv 一致（都走 Flutter Texture），故 Dart 侧无需分支。
        Media3Channel(this, flutterEngine.renderer).register(flutterEngine)

        // 播放器要用的系统能力：亮度 / 音量 / 唤醒锁。
        //
        // 为什么自己写而不用插件：这三件事各只需十几行系统 API，
        // 而对应插件会各带一棵依赖树（本项目已因 media_kit 的依赖树
        // 吃过亏 —— ADR 0009 把它换成了自持 libmpv）。
        //
        // 单位统一为 0-100（原生 API 各不同：亮度 0.0-1.0、
        // 音量是整数档位、唤醒锁无值），换算全在 SystemChannel 内完成。
        SystemChannel(this).register(flutterEngine)

        // 媒体会话（K3 / CF-P3-KERNEL-004）：通知栏 + 蓝牙耳机键 + 后台 + 音频焦点。
        //
        // ⚠️ **必须在两个内核之后注册**：`register()` 里会设置
        //    `PlayerSessionRegistry.commandSink`，那正是内核把会话命令
        //    回传给 Dart 的出口。反过来的话，早期命令会丢。
        //
        // 会话的命令**不直接操作内核**，而是回 Dart 走 `PlaybackController`
        // （唯一控制入口）—— 避免"两个主"导致通知栏与实际状态不一致。
        SessionChannel(this, flutterEngine.dartExecutor.binaryMessenger).register()
    }
}