/*
 * CineFlow 原生 mpv JNI 桥（Android）。
 *
 * ── 架构参考（两者都走 **Surface → wid** 路线，都不用 mpv_render_context）──
 *   - mpv-android  https://github.com/mpv-android/mpv-android
 *       app/src/main/jni/render.cpp：attachSurface → mpv_set_option("wid", int64)
 *       由 mpv 内部用 gpu-context=android 自建 EGL。
 *   - media_kit_video（本项目原先正在用、且已验证可跑）
 *       VideoOutput.java：TextureRegistry.createSurfaceProducer() → Surface
 *       → newGlobalObjectRef(surface)（JNI 全局引用）→ 作为 wid 交给 libmpv。
 *
 * ── 为什么**不**用 mpv_render_context ──
 *   1) 上游 mpv-android 根本没用它，Android 上没有可对照的范例；
 *   2) render API 硬性要求"GL 上下文必须在调用线程 current，且与创建时同源"，
 *      而 Flutter PlatformView 的合成时序不受我们控制，坑深且难验证；
 *   3) 走 Flutter texture 时视频是**普通纹理**，弹幕 overlay / 手势 / 控制层
 *      天然叠在上面，完全不需要 PlatformView 的手势仲裁。
 *
 * ⚠️ wid 的生命周期要点（本文件最容易搞错的地方）：
 *   - mpv 的 `wid` 必须在 **mpv_initialize 之前** 用 mpv_set_option 设好；
 *     initialize 之后再设不生效（见 client.h 对 mpv_create 的说明：
 *     "before mpv 0.21.0 mpv_set_option() etc." 讲的正是这个边界）。
 *     故 Kotlin 侧顺序被固定为：先建 Surface（拿全局引用）→ 再 initialize。
 *   - Surface 必须是 **JNI 全局引用**：mpv 会把它当 jobject，
 *     经 ANativeWindow_fromSurface 取窗口；局部引用在 JNI 调用返回后即失效。
 */
#include <android/log.h>
#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mpv/client.h>

/*
 * ★★ mpv 的 Android 视频输出**必须**先拿到 JavaVM，否则起播即失败 ★★
 *
 * 实测（真机 logcat，未注册时）：
 *   [mpv/vo/gpu/android] No Java virtual machine has been registered
 *   [mpv/vo/gpu/android] Could not attach java VM.
 *   [mpv/vo/gpu] Failed initializing any suitable GPU context!
 *   [mpv/cplayer] Error opening/initializing the selected video_out (--vo) device.
 *   → end-file error（Dart 侧只看到"播放失败（内核报错）"）
 *
 * 原因：`gpu-context=android` 要用 ANativeWindow_fromSurface(JNIEnv*, jobject)
 * 把 `wid`（我们存的 Surface 全局引用）转成原生窗口，而它需要一个 JNIEnv；
 * mpv 是通过 FFmpeg 的 av_jni_* 接口拿 JavaVM 的，**必须由宿主注册**。
 * mpv-android 在 main.cpp 里做的正是这件事。
 *
 * 注意：这个坑**解封装阶段看不出来**——上面日志里 h264/aac 各 5 条轨道
 * 都正常列出了，只有视频输出初始化失败。所以"能解析出轨道"不等于"能播"。
 */
extern int av_jni_set_java_vm(void *vm, void *log_ctx);

#define TAG "CineFlowMPV"
#define LOGV(...) __android_log_print(ANDROID_LOG_VERBOSE, TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

/* ⚠️ 必须用 #if 而不是 #ifdef：CMake 在"无 libmpv 的 ABI"上会传
 * -DCINEFLOW_HAS_MPV=0，而 #ifdef 只判断"是否定义"——值为 0 也算定义，
 * 于是桩代码会被编成真实现，运行时链接不到 mpv_* 符号。 */
#ifndef CINEFLOW_HAS_MPV
#define CINEFLOW_HAS_MPV 0
#endif
#if CINEFLOW_HAS_MPV
#define CF_MPV 1
#else
#define CF_MPV 0
#endif

static JavaVM *g_vm = NULL;
static jclass g_mpvlib_class = NULL;
static jmethodID g_on_event_mid = NULL;

/* mpv 实例，以及挂载的 Surface 全局引用（int64 形式的 wid） */
static mpv_handle *g_mpv = NULL;
static jobject g_surface_ref = NULL;
static int64_t g_wid = 0;
static pthread_t g_event_thread;
static volatile int g_event_running = 0;
static int g_event_thread_started = 0;

/* 线程本地：记住本线程是不是"我们 attach 的"。
 * 若别的代码已经 attach 过，我们就不能 Detach（会破坏别人的 JNIEnv）。 */
static __thread int t_attached_by_us = 0;

static JNIEnv *get_env(void) {
    JNIEnv *env = NULL;
    if (!g_vm) return NULL;
    if ((*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6) == JNI_OK) return env;
    if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) == JNI_OK) {
        t_attached_by_us = 1;
        return env;
    }
    return NULL;
}

static void release_env(void) {
    if (t_attached_by_us && g_vm) {
        (*g_vm)->DetachCurrentThread(g_vm);
        t_attached_by_us = 0;
    }
}

/* ---------------- JSON 输出（带转义 + 动态扩容） ---------------- */

typedef struct {
    char *buf;
    size_t len;
    size_t cap;
} sb_t;

static void sb_init(sb_t *sb, size_t cap) {
    sb->buf = (char *)malloc(cap);
    sb->len = 0;
    sb->cap = cap;
    if (sb->buf) sb->buf[0] = '\0';
}

static void sb_free(sb_t *sb) {
    free(sb->buf);
    sb->buf = NULL;
    sb->len = sb->cap = 0;
}

static void sb_reserve(sb_t *sb, size_t extra) {
    if (!sb->buf) return;
    if (sb->len + extra + 1 <= sb->cap) return;
    size_t ncap = sb->cap ? sb->cap : 256;
    while (sb->len + extra + 1 > ncap) ncap *= 2;
    char *nb = (char *)realloc(sb->buf, ncap);
    if (!nb) return;
    sb->buf = nb;
    sb->cap = ncap;
}

static void sb_raw(sb_t *sb, const char *s) {
    if (!sb->buf || !s) return;
    size_t n = strlen(s);
    sb_reserve(sb, n);
    if (sb->len + n + 1 > sb->cap) return;
    memcpy(sb->buf + sb->len, s, n);
    sb->len += n;
    sb->buf[sb->len] = '\0';
}

static void sb_char(sb_t *sb, char c) {
    sb_reserve(sb, 1);
    if (sb->len + 2 > sb->cap) return;
    sb->buf[sb->len++] = c;
    sb->buf[sb->len] = '\0';
}

/* 把 s 作为 JSON 字符串写入（含首尾引号）。
 * 必须转义：mpv 的日志与 track-list 里带引号/换行，
 * 不转义会让整个事件变成非法 JSON，Dart 侧 jsonDecode 抛异常后**静默丢弃**。 */
static void sb_json_string(sb_t *sb, const char *s) {
    sb_char(sb, '"');
    if (!s) {
        sb_char(sb, '"');
        return;
    }
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"':  sb_raw(sb, "\\\""); break;
        case '\\': sb_raw(sb, "\\\\"); break;
        case '\n': sb_raw(sb, "\\n");  break;
        case '\r': sb_raw(sb, "\\r");  break;
        case '\t': sb_raw(sb, "\\t");  break;
        case '\b': sb_raw(sb, "\\b");  break;
        case '\f': sb_raw(sb, "\\f");  break;
        default:
            if (*p < 0x20) {
                char esc[8];
                snprintf(esc, sizeof(esc), "\\u%04x", *p);
                sb_raw(sb, esc);
            } else {
                sb_char(sb, (char)*p);
            }
        }
    }
    sb_char(sb, '"');
}

static void sb_json_number(sb_t *sb, double v) {
    char n[64];
    snprintf(n, sizeof(n), "%.6f", v);
    sb_raw(sb, n);
}

static void sb_json_bool(sb_t *sb, int v) { sb_raw(sb, v ? "true" : "false"); }

static void call_kotlin_event(const char *json) {
    if (!g_mpvlib_class || !g_on_event_mid) return;
    JNIEnv *env = get_env();
    if (!env) return;
    jstring j = (*env)->NewStringUTF(env, json ? json : "");
    if (j) {
        (*env)->CallStaticVoidMethod(env, g_mpvlib_class, g_on_event_mid, j);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        (*env)->DeleteLocalRef(env, j);
    }
    release_env();
}

static void emit_property_number(const char *name, double v) {
    sb_t sb;
    sb_init(&sb, 128);
    sb_raw(&sb, "{\"type\":\"property\",\"name\":");
    sb_json_string(&sb, name);
    sb_raw(&sb, ",\"data\":");
    sb_json_number(&sb, v);
    sb_raw(&sb, "}");
    call_kotlin_event(sb.buf);
    sb_free(&sb);
}

static void emit_property_flag(const char *name, int v) {
    sb_t sb;
    sb_init(&sb, 128);
    sb_raw(&sb, "{\"type\":\"property\",\"name\":");
    sb_json_string(&sb, name);
    sb_raw(&sb, ",\"data\":");
    sb_json_bool(&sb, v);
    sb_raw(&sb, "}");
    call_kotlin_event(sb.buf);
    sb_free(&sb);
}

/* 字符串属性（aid/sid 可能是 "no"/"auto"，track-list 是一段 JSON 文本）
 * —— 一律作为 **JSON 字符串** 输出，由 Dart 侧决定是否再 jsonDecode。
 * 早期版本把 aid 裸拼成 data:no → 非法 JSON → 音轨切换事件全丢。 */
static void emit_property_string(const char *name, const char *v) {
    sb_t sb;
    sb_init(&sb, 512);
    sb_raw(&sb, "{\"type\":\"property\",\"name\":");
    sb_json_string(&sb, name);
    sb_raw(&sb, ",\"data\":");
    if (v) {
        sb_json_string(&sb, v);
    } else {
        sb_raw(&sb, "null");
    }
    sb_raw(&sb, "}");
    call_kotlin_event(sb.buf);
    sb_free(&sb);
}

#if CF_MPV
/* ---------------- 事件线程：mpv_wait_event → Kotlin ---------------- */

static void handle_property(mpv_event_property *p) {
    if (!p->name || !p->data) return;

    if (strcmp(p->name, "time-pos") == 0 || strcmp(p->name, "duration") == 0 ||
        strcmp(p->name, "demuxer-cache-time") == 0 || strcmp(p->name, "speed") == 0) {
        if (p->format == MPV_FORMAT_DOUBLE) emit_property_number(p->name, *(double *)p->data);
        return;
    }
    if (strcmp(p->name, "pause") == 0 || strcmp(p->name, "eof-reached") == 0 ||
        strcmp(p->name, "paused-for-cache") == 0) {
        if (p->format == MPV_FORMAT_FLAG) emit_property_flag(p->name, *(int *)p->data);
        return;
    }
    if (strcmp(p->name, "volume") == 0) {
        if (p->format == MPV_FORMAT_DOUBLE) emit_property_number(p->name, *(double *)p->data);
        return;
    }
    /* 视频原始尺寸：Dart 侧据此算宽高比（FittedBox 里用），
     * 否则只能猜 16:9，遇到 4:3 / 2.35:1 片源会变形或留错黑边。 */
    if (strcmp(p->name, "width") == 0 || strcmp(p->name, "height") == 0) {
        if (p->format == MPV_FORMAT_INT64) {
            emit_property_number(p->name, (double)(*(int64_t *)p->data));
        }
        return;
    }
    if (strcmp(p->name, "aid") == 0 || strcmp(p->name, "sid") == 0) {
        /* aid/sid 是字符串属性；关掉时值为 "no"，未定时可能是 "auto" */
        if (p->format == MPV_FORMAT_STRING) {
            emit_property_string(p->name, *(char **)p->data);
        } else if (p->format == MPV_FORMAT_NONE) {
            emit_property_string(p->name, "no");
        }
        return;
    }
    if (strcmp(p->name, "track-list") == 0) {
        if (p->format == MPV_FORMAT_STRING) emit_property_string("track-list", *(char **)p->data);
        return;
    }
}

static void handle_event(mpv_event *ev) {
    switch (ev->event_id) {
    case MPV_EVENT_LOG_MESSAGE: {
        mpv_event_log_message *m = (mpv_event_log_message *)ev->data;
        /* 同时落 logcat：Dart 侧把 log 事件丢了，排障时这里是唯一线索 */
        __android_log_print(ANDROID_LOG_INFO, TAG, "[mpv/%s] %s",
                            m->prefix ? m->prefix : "", m->text ? m->text : "");
        sb_t sb;
        sb_init(&sb, 512);
        sb_raw(&sb, "{\"type\":\"log\",\"prefix\":");
        sb_json_string(&sb, m->prefix ? m->prefix : "");
        sb_raw(&sb, ",\"text\":");
        sb_json_string(&sb, m->text ? m->text : "");
        sb_raw(&sb, "}");
        call_kotlin_event(sb.buf);
        sb_free(&sb);
        break;
    }
    case MPV_EVENT_PROPERTY_CHANGE:
        handle_property((mpv_event_property *)ev->data);
        break;
    case MPV_EVENT_END_FILE: {
        mpv_event_end_file *ef = (mpv_event_end_file *)ev->data;
        const char *reason = "other";
        switch (ef->reason) {
        case MPV_END_FILE_REASON_EOF:   reason = "eof";   break;
        case MPV_END_FILE_REASON_STOP:  reason = "stop";  break;
        case MPV_END_FILE_REASON_QUIT:  reason = "quit";  break;
        case MPV_END_FILE_REASON_ERROR: reason = "error"; break;
        default: break;
        }
        /* ★ 把 mpv 的原始错误串同时写进 logcat。
         * Dart 侧只拿到"内核报错"这个笼统结论，排障时必须看到
         * mpv 到底报了什么（TLS/编解码/404 的处置完全不同）。 */
        if (ef->reason == MPV_END_FILE_REASON_ERROR) {
            LOGE("end-file error: %s (error=%d %s)", reason, ef->error,
                 mpv_error_string(ef->error));
        } else {
            LOGI("end-file: %s", reason);
        }
        sb_t sb;
        sb_init(&sb, 160);
        sb_raw(&sb, "{\"type\":\"end-file\",\"reason\":");
        sb_json_string(&sb, reason);
        if (ef->reason == MPV_END_FILE_REASON_ERROR) {
            sb_raw(&sb, ",\"error\":");
            sb_json_string(&sb, mpv_error_string(ef->error));
        }
        sb_raw(&sb, "}");
        call_kotlin_event(sb.buf);
        sb_free(&sb);
        break;
    }
    default:
        break;
    }
}

static void *event_loop(void *arg) {
    (void)arg;
    JNIEnv *env = get_env();
    if (!env) return NULL;
    while (g_event_running) {
        mpv_event *ev = mpv_wait_event(g_mpv, 0.2);
        if (!ev) continue;
        if (ev->event_id == MPV_EVENT_NONE) continue;
        if (ev->event_id == MPV_EVENT_SHUTDOWN) break;
        handle_event(ev);
    }
    release_env();
    return NULL;
}
#endif /* CF_MPV */

/* ---------------- JNI 导出（对应 MPVLib.kt 的 external fun） ---------------- */

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    g_vm = vm;
#if CF_MPV
    /* ★ 在这里注册给 FFmpeg/mpv 是最早且最安全的时机：
     * JNI_OnLoad 一定在 System.loadLibrary 期间、任何 mpv_* 调用之前发生。
     * 放到 nativeCreate 里也行，但如果有人先调了 nativeInit 就会漏。
     *
     * ⚠️ 必须包在 #if CF_MPV 里：v7a / x86_64 没有 libmpv.so（桩构建），
     * 不包就会在那些 ABI 上以 "undefined symbol: av_jni_set_java_vm" 链接失败
     * ——而 arm64 单独构建是过的，故只在全 ABI 构建时才暴露（实测踩过）。 */
    int r = av_jni_set_java_vm(vm, NULL);
    LOGI("av_jni_set_java_vm -> %d (0=成功)", r);
#endif
    return JNI_VERSION_1_6;
}

static void cache_class(JNIEnv *env) {
    if (g_mpvlib_class) return;
    jclass c = (*env)->FindClass(env, "com/cineflow/app/player/MPVLib");
    if (!c) return;
    g_mpvlib_class = (jclass)(*env)->NewGlobalRef(env, c);
    g_on_event_mid = (*env)->GetStaticMethodID(env, c, "onEvent", "(Ljava/lang/String;)V");
    (*env)->DeleteLocalRef(env, c);
}

/*
 * 挂载渲染目标：把 android.view.Surface 存成 **JNI 全局引用**，
 * 作为 mpv 的 wid（int64）。必须在 nativeInit 之前调用。
 */
JNIEXPORT jboolean JNICALL
Java_com_cineflow_app_player_MPVLib_attachSurface(JNIEnv *env, jclass clazz, jobject surface) {
    (void)clazz;
    if (g_surface_ref) {
        (*env)->DeleteGlobalRef(env, g_surface_ref);
        g_surface_ref = NULL;
        g_wid = 0;
    }
    if (!surface) {
        LOGE("attachSurface: surface 为 null");
        return JNI_FALSE;
    }
    g_surface_ref = (*env)->NewGlobalRef(env, surface);
    g_wid = (int64_t)(intptr_t)g_surface_ref;
    LOGI("attachSurface: wid=%lld", (long long)g_wid);
    return g_surface_ref ? JNI_TRUE : JNI_FALSE;
}

/* 解绑：Surface 被销毁时必须调，否则 mpv 会往已释放的 ANativeWindow 上画。 */
JNIEXPORT void JNICALL
Java_com_cineflow_app_player_MPVLib_detachSurface(JNIEnv *env, jclass clazz) {
    (void)clazz;
    if (g_surface_ref) {
        (*env)->DeleteGlobalRef(env, g_surface_ref);
        g_surface_ref = NULL;
    }
    g_wid = 0;
    LOGI("detachSurface");
}

JNIEXPORT void JNICALL
Java_com_cineflow_app_player_MPVLib_nativeCreate(JNIEnv *env, jclass clazz) {
    (void)clazz;
    cache_class(env);
#if CF_MPV
    if (g_mpv) return;
    g_mpv = mpv_create();
    if (!g_mpv) LOGE("mpv_create 失败");
#else
    LOGE("本 ABI 未编入 libmpv（CINEFLOW_HAS_MPV=0）");
#endif
}

JNIEXPORT void JNICALL
Java_com_cineflow_app_player_MPVLib_nativeInit(JNIEnv *env, jclass clazz) {
    (void)env; (void)clazz;
#if CF_MPV
    if (!g_mpv) return;

    /* ★ wid 必须在 initialize 之前设成 option —— 之后再设不再生效 */
    if (g_wid) {
        int64_t wid = g_wid;
        int r = mpv_set_option(g_mpv, "wid", MPV_FORMAT_INT64, &wid);
        if (r < 0) {
            LOGE("设置 wid 失败: %s", mpv_error_string(r));
        } else {
            LOGI("wid 已设定 = %lld", (long long)wid);
        }
    } else {
        LOGE("nativeInit 时没有 Surface —— 画面不会显示（Kotlin 侧顺序错了）");
    }

    if (mpv_initialize(g_mpv) < 0) { LOGE("mpv_initialize 失败"); return; }
    LOGI("mpv_initialize 成功，client API 版本=%lu", mpv_client_api_version());

    mpv_request_log_messages(g_mpv, "info");

    /* 属性观察：Dart 侧 KernelState / 事件全靠这些 */
    mpv_observe_property(g_mpv, 0, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(g_mpv, 0, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(g_mpv, 0, "demuxer-cache-time", MPV_FORMAT_DOUBLE);
    mpv_observe_property(g_mpv, 0, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(g_mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG);
    mpv_observe_property(g_mpv, 0, "eof-reached", MPV_FORMAT_FLAG);
    mpv_observe_property(g_mpv, 0, "speed", MPV_FORMAT_DOUBLE);
    mpv_observe_property(g_mpv, 0, "volume", MPV_FORMAT_DOUBLE);
    mpv_observe_property(g_mpv, 0, "aid", MPV_FORMAT_STRING);
    mpv_observe_property(g_mpv, 0, "sid", MPV_FORMAT_STRING);
    mpv_observe_property(g_mpv, 0, "track-list", MPV_FORMAT_STRING);
    /* 视频原始尺寸（宽高比要用） */
    mpv_observe_property(g_mpv, 0, "width", MPV_FORMAT_INT64);
    mpv_observe_property(g_mpv, 0, "height", MPV_FORMAT_INT64);

    g_event_running = 1;
    if (pthread_create(&g_event_thread, NULL, event_loop, NULL) == 0) {
        g_event_thread_started = 1;
    } else {
        g_event_running = 0;
        LOGE("事件线程创建失败");
    }
#endif
}

JNIEXPORT void JNICALL
Java_com_cineflow_app_player_MPVLib_nativeDestroy(JNIEnv *env, jclass clazz) {
    (void)env; (void)clazz;
#if CF_MPV
    /* 顺序很关键：先停并 join 事件线程，再 terminate。
     * 反过来做 = 线程还在 mpv_wait_event 而句柄已释放 → 退出播放器必崩。 */
    g_event_running = 0;
    if (g_event_thread_started) {
        pthread_join(g_event_thread, NULL);
        g_event_thread_started = 0;
    }
    if (g_mpv) {
        mpv_terminate_destroy(g_mpv);
        g_mpv = NULL;
    }
    LOGI("mpv 已销毁");
#endif
}

JNIEXPORT void JNICALL
Java_com_cineflow_app_player_MPVLib_setOptionString(JNIEnv *env, jclass clazz,
                                                    jstring option, jstring value) {
    (void)clazz;
#if CF_MPV
    if (!g_mpv || !option || !value) return;
    const char *o = (*env)->GetStringUTFChars(env, option, NULL);
    const char *v = (*env)->GetStringUTFChars(env, value, NULL);
    if (o && v) {
        int r = mpv_set_option_string(g_mpv, o, v);
        if (r < 0) LOGV("setOption %s=%s -> %s", o, v, mpv_error_string(r));
    }
    if (o) (*env)->ReleaseStringUTFChars(env, option, o);
    if (v) (*env)->ReleaseStringUTFChars(env, value, v);
#endif
}

JNIEXPORT void JNICALL
Java_com_cineflow_app_player_MPVLib_setPropertyString(JNIEnv *env, jclass clazz,
                                                      jstring property, jstring value) {
    (void)clazz;
#if CF_MPV
    if (!g_mpv || !property || !value) return;
    const char *p = (*env)->GetStringUTFChars(env, property, NULL);
    const char *v = (*env)->GetStringUTFChars(env, value, NULL);
    if (p && v) {
        int r = mpv_set_property_string(g_mpv, p, v);
        if (r < 0) LOGV("setProperty %s=%s -> %s", p, v, mpv_error_string(r));
    }
    if (p) (*env)->ReleaseStringUTFChars(env, property, p);
    if (v) (*env)->ReleaseStringUTFChars(env, value, v);
#endif
}

JNIEXPORT jstring JNICALL
Java_com_cineflow_app_player_MPVLib_getPropertyString(JNIEnv *env, jclass clazz,
                                                      jstring property) {
    (void)clazz;
#if CF_MPV
    if (!g_mpv || !property) return (*env)->NewStringUTF(env, "");
    const char *p = (*env)->GetStringUTFChars(env, property, NULL);
    if (!p) return (*env)->NewStringUTF(env, "");
    char *v = mpv_get_property_string(g_mpv, p);
    jstring r = (*env)->NewStringUTF(env, v ? v : "");
    if (v) mpv_free(v);
    (*env)->ReleaseStringUTFChars(env, property, p);
    return r;
#else
    return (*env)->NewStringUTF(env, "");
#endif
}

JNIEXPORT void JNICALL
Java_com_cineflow_app_player_MPVLib_command(JNIEnv *env, jclass clazz, jobjectArray args) {
    (void)clazz;
#if CF_MPV
    if (!g_mpv || !args) return;
    jsize n = (*env)->GetArrayLength(env, args);
    if (n <= 0) return;
    const char **argv = (const char **)calloc((size_t)n + 1, sizeof(char *));
    if (!argv) return;
    for (jsize i = 0; i < n; i++) {
        jstring j = (jstring)(*env)->GetObjectArrayElement(env, args, i);
        if (!j) { argv[i] = strdup(""); continue; }
        const char *s = (*env)->GetStringUTFChars(env, j, NULL);
        argv[i] = strdup(s ? s : "");
        if (s) (*env)->ReleaseStringUTFChars(env, j, s);
        (*env)->DeleteLocalRef(env, j);
    }
    argv[n] = NULL;
    int r = mpv_command(g_mpv, argv);
    if (r < 0) LOGV("command[%s] -> %s", argv[0] ? argv[0] : "", mpv_error_string(r));
    for (jsize i = 0; i < n; i++) free((void *)argv[i]);
    free(argv);
#endif
}
