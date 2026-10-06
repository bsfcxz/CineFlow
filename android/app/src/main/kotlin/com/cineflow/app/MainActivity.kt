package com.cineflow.app

import com.cineflow.app.player.PlayerChannel
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
    }
}
