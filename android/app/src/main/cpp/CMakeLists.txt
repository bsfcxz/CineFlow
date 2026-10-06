cmake_minimum_required(VERSION 3.18)
project(cineflow_mpv C)

# ---------------------------------------------------------------------------
# 原生 mpv JNI 桥（安卓）
#
# 参考（两者都是 Surface → wid 路线）：
#   - mpv-android  https://github.com/mpv-android/mpv-android
#       app/src/main/jni/render.cpp（attachSurface → mpv_set_option("wid")）
#   - media_kit_video  VideoOutput.java（TextureRegistry.SurfaceProducer → wid）
#
# 本桥不做任何 GL/EGL：渲染上下文由 mpv 自己用 gpu-context=android 创建，
# 我们只把 Flutter 纹理的 Surface 交给它。故**不需要**链接 EGL/GLES。
#
# ⚠️ include 路径必须是 cpp/include（不是 cpp/include/mpv）——
#    源码写的是 #include <mpv/client.h>，前缀已经带了 mpv/。
# ---------------------------------------------------------------------------

add_library(cineflow_mpv SHARED cineflow_mpv.c)

target_include_directories(cineflow_mpv PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)

find_library(log-lib log)
find_library(android-lib android)

# libmpv.so 由 jniLibs 提供（按 ABI 分目录）。
# 本工程实际只发布 arm64-v8a（libcineflow_go.so 同样只有 arm64），
# 故其它 ABI 下退化为"无 mpv 的桩"，避免 flutter build apk 全 ABI 构建直接失败。
set(MPV_LIB "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libmpv.so")

if(EXISTS "${MPV_LIB}")
    message(STATUS "cineflow_mpv: 使用 ${ANDROID_ABI} 的 libmpv.so -> ${MPV_LIB}")
    add_library(mpv SHARED IMPORTED)
    set_target_properties(mpv PROPERTIES IMPORTED_LOCATION "${MPV_LIB}")
    target_compile_definitions(cineflow_mpv PRIVATE CINEFLOW_HAS_MPV=1)
    target_link_libraries(cineflow_mpv mpv ${log-lib} ${android-lib})
else()
    message(WARNING "cineflow_mpv: ${ANDROID_ABI} 无 libmpv.so —— 该 ABI 编出的是空实现桩")
    target_compile_definitions(cineflow_mpv PRIVATE CINEFLOW_HAS_MPV=0)
    target_link_libraries(cineflow_mpv ${log-lib} ${android-lib})
endif()
