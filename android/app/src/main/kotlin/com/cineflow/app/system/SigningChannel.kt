package com.cineflow.app.system

import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/**
 * **签名指纹通道**（`com.cineflow.app/signing`）。
 *
 * ## 为什么需要它（用户要求"内置 Client ID 且不公开"）
 * 用户要求把 Trakt Client ID 内置进 APK，并要求"加密"。
 *
 * ### 先说实话：这不是加密，是**签名绑定混淆**
 * 我们能做到的是：把 Client ID 用「**APK 签名证书的 SHA-256**」派生的密钥
 * 做 XOR，密文以常量内置。
 * · ✅ **换签名重打包 ⇒ 解不出明文**（挡住"改包重发"）
 * · ❌ **挡不住反编译** —— 证书指纹本身也在 APK 里
 *   （APK 里的 `META-INF` 目录有 `.RSA` 证书文件），
*   会逆向的人照样能算密钥
*
* ⚠️ **Kotlin 的块注释可嵌套**（Java 不可）：
*   若注释正文里出现「斜杠 + 星号」这个两字符组合，
*   Kotlin 会把它当成**新开一层嵌套注释** ⇒ 需要多一个结束标记才闭合
*   ⇒ 报 `Syntax error: Unclosed comment`（指到文件末尾，很难定位）。
*
*   ★ 本文件**踩过两次**：第一次是路径里的通配（`META-INF` 下的证书文件）；
*     第二次是我写这条警告时**又把那两个字符写进了注释里**（自证式复现）。
*   ⇒ 结论：这个文件（以及任何 Kotlin 块注释）**永远不要写出那两个字符**。
 * ⇒ 所以它是**混淆（obfuscation）**，不是加密（encryption）。
 *   本注释如实标注，避免后来者误以为"有了安全保证"。
 *
 * ### 与「App Links 数字资产校验」的区别
 * Android 官方的 App Links 用 `assetlinks.json` 做**服务端签发**的绑定
 * （服务端声明"只有这个签名的 App 能接管该域名"）。
 * 我们这里没有服务端配合 ⇒ 只能做**客户端自校验**，强度低一档。
 *
 * ## 为什么放 SystemChannel 之外单独一个通道
 * `SystemChannel` 管的是亮度/音量/唤醒锁（播放相关），
 * 签名指纹是**应用身份**相关 ⇒ 混在一起会让两边都难读。
 * 照它 `register(flutterEngine)` 的模式即可。
 */
class SigningChannel(private val activity: android.app.Activity) {

    companion object {
        const val CHANNEL = "com.cineflow.app/signing"
        private const val TAG = "CF-Signing"

        /** 取**签名证书**的 SHA-256（hex，小写）。 */
        fun signatureSha256(activity: android.app.Activity): String? {
            return try {
                val pm = activity.packageManager
                val pkg = activity.packageName
                val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES)
                    val si = info.signingInfo
                    if (si == null) {
                        null
                    } else if (si.hasMultipleSigners()) {
                        si.apkContentsSigners
                    } else {
                        si.signingCertificateHistory
                    }
                } else {
                    @Suppress("DEPRECATION")
                    val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNATURES)
                    @Suppress("DEPRECATION")
                    info.signatures
                }
                val first = signatures?.firstOrNull() ?: return null
                val md = MessageDigest.getInstance("SHA-256")
                val digest = md.digest(first.toByteArray())
                digest.joinToString("") { b -> "%02x".format(b) }
            } catch (e: Exception) {
                Log.e(TAG, "取签名指纹失败", e)
                null
            }
        }
    }

    fun register(flutterEngine: FlutterEngine) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "sha256" -> {
                    val v = signatureSha256(activity)
                    if (v == null) {
                        // ⚠️ 拿不到指纹 ⇒ 返回 error 而**不是**空串
                        //    （调用方据此决定"不解密、不启用内置凭据"，
                        //     而不是拿空串去派生密钥 ⇒ 那会解出乱码）
                        result.error("NO_SIGNATURE", "无法读取签名指纹", null)
                    } else {
                        result.success(v)
                    }
                }
                "packageName" -> result.success(activity.packageName)
                else -> result.notImplemented()
            }
        }
    }
}
