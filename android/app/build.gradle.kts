// 读 key.properties 需要显式 import：
// Gradle Kotlin DSL 的隐式 import 不含 `java.util`，
// 写 `java.util.Properties()` 会报 "Unresolved reference 'util'"（实测踩过）。
// Kotlin 要求 import 必须在文件顶部（在 plugins 块之前）。
import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---- release 正式签名配置 ----
//
// ## 为什么 keystore 放仓库外
//
// 签名私钥与口令**绝不可入库**（AGENTS.md 安全红线）。
// keystore 放在 `%USERPROFILE%\cineflow-keystore\`（**仓库外**），
// 物理上不可能被 `git add`；`key.properties` 记路径与口令，已被
// `android/.gitignore` 忽略。
//
// 查找顺序：
//   1. 环境变量 `CF_KEY_PROPERTIES` 指定的文件（CI / 多机场景）
//   2. 仓库外默认位置 `%USERPROFILE%/cineflow-keystore/key.properties`
//   3. 仓库内 `android/key.properties`（兼容常见做法，仍被 gitignore）
//
// ## 缺失时回退 debug 签名并**告警**，而不是直接构建失败
//
// 理由：日常开发（`flutter run --release`、真机调试）不该因为拿不到私钥就跑不起来。
// 但**发布**必须用正式签名 —— 故 `tool/verify_signing.ps1` 会硬性检查，
// release.yml 也在上传前校验。
// 读 key.properties。
// ⚠️ 用 `Properties` + 显式 `load(InputStream)`，并在文件顶部 import
//    （Gradle Kotlin DSL 隐式 import 没有 java.util，实测踩过）。
//
// ⚠️⚠️ CI 上**必须**用 `providers.environmentVariable`：
//    `System.getenv()` 读的是 **Gradle daemon 进程**的环境变量，
//    而 daemon 是长驻的 —— 它的环境在**启动那一刻**就固定了。
//    `flutter build apk` 之后再 export 的变量，daemon **看不到**。
//    实测踩过：CI 里 CF_KEY_PROPERTIES 明明已写进 $GITHUB_ENV，
//    构建出的 APK 却仍是 debug 签名（守卫步骤拦下了）。
//    `providers.environmentVariable()` 是 Gradle 的**惰性 provider**，
//    会被正确追踪与失效，不受 daemon 影响。
val cfKeyPropsFile: File? = run {
    val fromProvider = providers.environmentVariable("CF_KEY_PROPERTIES")
        .orNull?.takeIf { it.isNotBlank() }
    val fromEnv = System.getenv("CF_KEY_PROPERTIES")?.takeIf { it.isNotBlank() }
    val candidates = listOfNotNull(
        fromProvider?.let { File(it) },
        fromEnv?.let { File(it) },
        // 仓库内 android/key.properties（Flutter 官方推荐位置，已被 gitignore）
        rootProject.file("key.properties"),
        // 仓库外默认位置（本机开发）
        File(System.getProperty("user.home"), "cineflow-keystore/key.properties"),
    )
    candidates.firstOrNull { it.exists() }
}

// 打印实际用到的位置 —— 否则"配了却没生效"极难排查（本次 CI 就栽在这）
logger.lifecycle(
    if (cfKeyPropsFile != null) "cineflow signing: 使用 $cfKeyPropsFile"
    else "cineflow signing: 未找到 key.properties（将回退 debug 签名）"
)

val cfKeyProps = Properties()
if (cfKeyPropsFile != null) {
    FileInputStream(cfKeyPropsFile).use { ins -> cfKeyProps.load(ins) }
}

val cfHasReleaseKey = cfKeyPropsFile != null &&
    !cfKeyProps.getProperty("storeFile").isNullOrBlank()

android {
    namespace = "com.cineflow.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.cineflow.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 不要在这里加 ndk.abiFilters：与 --split-per-abi 的 splits 配置互斥会构建失败；
        // 架构精简统一走 tool/build_apk.sh（--split-per-abi）。

        // Patrol 真机 UI 测试：由 PatrolJUnitRunner 驱动 Dart 测试用例，
        // clearPackageData 保证每个用例在干净的应用数据上启动。
        testInstrumentationRunner = "pl.leancode.patrol.PatrolJUnitRunner"
        testInstrumentationRunnerArguments["clearPackageData"] = "true"
    }

    // Patrol 要求用 AndroidX Test Orchestrator 隔离每个测试用例，
    // 避免用例之间通过进程状态互相污染。
    testOptions {
        execution = "ANDROIDX_TEST_ORCHESTRATOR"
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        if (cfHasReleaseKey) {
            create("release") {
                storeFile = file(cfKeyProps.getProperty("storeFile"))
                storePassword = cfKeyProps.getProperty("storePassword")
                keyAlias = cfKeyProps.getProperty("keyAlias")
                keyPassword = cfKeyProps.getProperty("keyPassword")
                // v2/v3 是现代 Android 的校验方式（minSdk 24 起 v1 非必需，
                // 但保留不影响，且便于部分老工具链验签）
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            // 有正式签名就用；没有则回退 debug 并打印醒目告警。
            // ⚠️ 发布包**必须**是正式签名 —— 由 tool/verify_signing.ps1 硬性把关。
            signingConfig = if (cfHasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "⚠️ 未找到 release 签名配置，回退 debug 签名 —— " +
                    "此包**不可用于正式分发**！查找位置：CF_KEY_PROPERTIES、" +
                    "%USERPROFILE%/cineflow-keystore/key.properties、android/key.properties"
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Patrol 的测试编排器（配合上面的 testOptions.execution 使用）
    androidTestUtil("androidx.test:orchestrator:1.5.1")
}

flutter {
    source = "../.."
    // 注意：Flutter 插件自带库（libflutter/libmpv/libapp）的目标架构不受
    // ndk.abiFilters 控制，发布请用 tool/build_apk.sh（--target-platform android-arm64）。
}
