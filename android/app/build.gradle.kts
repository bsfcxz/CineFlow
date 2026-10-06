plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
