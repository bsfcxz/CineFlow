package com.cineflow.app

import com.cineflow.app.player.PlayerChannel
import com.cineflow.app.system.SystemChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 原生 mpv 播放通道：MethodChannel 命令 + EventChannel 事件 +
        // Flutter 纹理（视频输出走 TextureRegistry，不用 PlatformView）。
        val channel = PlayerChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer,
        )
        channel.register()

        // 播放器要用的系统能力：亮度 / 音量 / 唤醒锁。
        //
        // 为什么自己写而不用插件：这三件事各只需十几行系统 API，
        // 而对应插件会各带一棵依赖树（本项目已因 media_kit 的依赖树
        // 吃过亏 —— ADR 0009 把它换成了自持 libmpv）。
        //
        // 单位统一为 0–100（原生 API 各不同：亮度 0.0–1.0、
        // 音量是整数档位、唤醒锁无值），换算全在 SystemChannel 内完成。
        SystemChannel(this).register(flutterEngine)
    }
}