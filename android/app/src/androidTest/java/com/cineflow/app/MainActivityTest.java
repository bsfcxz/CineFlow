package com.cineflow.app;

import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.Parameterized;
import org.junit.runners.Parameterized.Parameters;
import pl.leancode.patrol.PatrolJUnitRunner;

/**
 * Patrol 真机 UI 测试的 Android 侧入口。
 *
 * <p>Patrol 的测试是 Dart 写的，但必须以 instrumentation 测试的形式在真机上跑起来。
 * 这个类就是两者的桥：它向 PatrolJUnitRunner 注册被测 Activity、等待 Patrol 的
 * Dart 服务端就绪、把 Dart 侧的所有测试列成一个参数化测试集，
 * 再由 JUnit 逐个执行 —— 每个 Dart 测试用例对应这里的一个参数。
 *
 * <p>被测 Activity 用 {@code MainActivity.class}（AndroidManifest.xml 里
 * activity 的 {@code android:name=".MainActivity"}，即 com.cineflow.app.MainActivity）。
 * 若将来改用 Flutter 默认的 FlutterActivity，需要同步改成
 * {@code io.flutter.embedding.android.FlutterActivity.class}。
 *
 * <p>包名必须与 applicationId 一致（android/app/build.gradle.kts 的
 * {@code applicationId = "com.cineflow.app"}），否则 MainActivity 无法解析。
 */
@RunWith(Parameterized.class)
public class MainActivityTest {
    @Parameters(name = "{0}")
    public static Object[] testCases() {
        PatrolJUnitRunner instrumentation = (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.setUp(MainActivity.class);
        instrumentation.waitForPatrolAppService();
        return instrumentation.listDartTests();
    }

    public MainActivityTest(String dartTestName) {
        this.dartTestName = dartTestName;
    }

    private final String dartTestName;

    @Test
    public void runDartTest() {
        PatrolJUnitRunner instrumentation = (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.runDartTest(dartTestName);
    }
}
