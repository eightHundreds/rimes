cmake_minimum_required(VERSION 3.22)

project(RIMESAndroid LANGUAGES CXX)

# Both variables are injected by app/build.gradle.kts.
if(NOT DEFINED RIMES_REPO_ROOT)
    message(FATAL_ERROR "RIMES_REPO_ROOT must point at the repository root")
endif()
if(NOT DEFINED RIMES_PREBUILT_DIR)
    message(FATAL_ERROR "RIMES_PREBUILT_DIR must point at platforms/android/third_party/prebuilt")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Pinned static librime and its dependencies (see scripts/fetch-prebuilt.sh).
# The librime archive already merges the lua, octagram and predict plugins, so
# the module list used by the shared bridge stays identical to macOS.
function(rimes_import_static name relative_path)
    set(location "${RIMES_PREBUILT_DIR}/${relative_path}")
    if(NOT EXISTS "${location}")
        message(FATAL_ERROR "Missing prebuilt archive ${location}; run platforms/android/scripts/fetch-prebuilt.sh")
    endif()
    add_library(${name} STATIC IMPORTED)
    set_target_properties(${name} PROPERTIES IMPORTED_LOCATION "${location}")
endfunction()

rimes_import_static(rimes_librime  "librime/${ANDROID_ABI}/lib/librime.a")
rimes_import_static(rimes_glog     "glog/${ANDROID_ABI}/lib/libglog.a")
rimes_import_static(rimes_leveldb  "leveldb/${ANDROID_ABI}/lib/libleveldb.a")
rimes_import_static(rimes_lua      "lua/${ANDROID_ABI}/lib/liblua_static.a")
rimes_import_static(rimes_marisa   "marisa/${ANDROID_ABI}/lib/libmarisa.a")
rimes_import_static(rimes_opencc   "opencc/${ANDROID_ABI}/lib/libopencc.a")
rimes_import_static(rimes_yamlcpp  "yaml-cpp/${ANDROID_ABI}/lib/libyaml-cpp.a")

add_library(rimes_jni SHARED
    rime_jni.cpp
    # The macOS bridge is compiled unchanged apart from its Android-only
    # library-loading branch. Its RimeApi vtable order stays load-bearing.
    "${RIMES_REPO_ROOT}/Sources/CRimeBridge/CRimeBridge.cpp"
)

target_include_directories(rimes_jni PRIVATE
    "${RIMES_REPO_ROOT}/Sources/CRimeBridge/include"
    "${RIMES_PREBUILT_DIR}/librime/${ANDROID_ABI}/include"
)

target_compile_options(rimes_jni PRIVATE -Wall -fvisibility=hidden)
target_compile_definitions(rimes_jni PRIVATE RIMES_ANDROID=1)

# Module registration in a static librime relies on static initialisers, so
# the whole archive must be kept (mirrors fcitx5-android's link line).
target_link_libraries(rimes_jni PRIVATE
    -Wl,--whole-archive
    rimes_librime
    -Wl,--no-whole-archive
    rimes_glog
    rimes_leveldb
    rimes_lua
    rimes_marisa
    rimes_opencc
    rimes_yamlcpp
    log
    android
)

target_link_options(rimes_jni PRIVATE
    "LINKER:--hash-style=gnu,--build-id=none"
    "LINKER:-z,max-page-size=16384"
)
