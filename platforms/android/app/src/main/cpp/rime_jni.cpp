// JNI adapter over the shared CRimeBridge C API.
//
// This file owns no Rime state of its own: every call is forwarded to the
// BBRime* functions that the macOS input method also uses, so session
// semantics, context snapshots, user-dictionary maintenance and the health gate
// behave identically on both platforms. Bridge-owned string pointers are copied
// into Java strings before the global bridge mutex is released by the next
// call, matching the "copy immediately" contract documented in CRimeBridge.h.

#include <jni.h>

#include <android/log.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "CRimeBridge.h"

namespace {

constexpr const char* kTag = "RimesJNI";
constexpr const char* kPackage = "com/isaac/inputmethod/rimes/rime/";

std::string toStdString(JNIEnv* env, jstring value) {
    if (!value) return {};
    const char* chars = env->GetStringUTFChars(value, nullptr);
    if (!chars) return {};
    std::string result(chars);
    env->ReleaseStringUTFChars(value, chars);
    return result;
}

// Bridge strings are UTF-8 produced by librime; NewStringUTF expects modified
// UTF-8 and rejects 4-byte sequences (emoji, CJK extension B). Decode through
// UTF-16 so every candidate survives the crossing.
jstring toJavaString(JNIEnv* env, const char* utf8) {
    if (!utf8) utf8 = "";
    std::vector<jchar> units;
    const unsigned char* p = reinterpret_cast<const unsigned char*>(utf8);
    while (*p) {
        uint32_t cp = 0;
        int extra = 0;
        if (*p < 0x80) {
            cp = *p;
        } else if ((*p & 0xE0) == 0xC0) {
            cp = *p & 0x1F;
            extra = 1;
        } else if ((*p & 0xF0) == 0xE0) {
            cp = *p & 0x0F;
            extra = 2;
        } else if ((*p & 0xF8) == 0xF0) {
            cp = *p & 0x07;
            extra = 3;
        } else {
            cp = 0xFFFD;
        }
        ++p;
        for (int i = 0; i < extra; ++i) {
            if ((*p & 0xC0) != 0x80) {
                cp = 0xFFFD;
                break;
            }
            cp = (cp << 6) | (*p & 0x3F);
            ++p;
        }
        if (cp > 0x10FFFF) cp = 0xFFFD;
        if (cp >= 0x10000) {
            cp -= 0x10000;
            units.push_back(static_cast<jchar>(0xD800 + (cp >> 10)));
            units.push_back(static_cast<jchar>(0xDC00 + (cp & 0x3FF)));
        } else {
            units.push_back(static_cast<jchar>(cp));
        }
    }
    return env->NewString(units.data(), static_cast<jsize>(units.size()));
}

jstring takeBridgeString(JNIEnv* env, char* owned) {
    if (!owned) return nullptr;
    jstring result = toJavaString(env, owned);
    BBRimeFreeString(owned);
    return result;
}

jclass findClass(JNIEnv* env, const char* leaf) {
    std::string name = std::string(kPackage) + leaf;
    jclass cls = env->FindClass(name.c_str());
    if (!cls) {
        __android_log_print(ANDROID_LOG_ERROR, kTag, "missing class %s", name.c_str());
    }
    return cls;
}

}  // namespace

extern "C" {

#define RIMES_JNI(ret, name) \
    JNIEXPORT ret JNICALL Java_com_isaac_inputmethod_rimes_rime_RimeBridge_##name

RIMES_JNI(jboolean, start)(JNIEnv* env, jclass,
                            jstring sharedDataDir,
                            jstring userDataDir,
                            jstring logDir) {
    const std::string shared = toStdString(env, sharedDataDir);
    const std::string user = toStdString(env, userDataDir);
    const std::string log = toStdString(env, logDir);
    const bool ok = BBRimeStart(shared.c_str(), user.c_str(), log.c_str(), "");
    if (!ok) {
        char* error = BBRimeCopyLastError();
        __android_log_print(ANDROID_LOG_ERROR, kTag, "rime start failed: %s",
                            error ? error : "unknown");
        BBRimeFreeString(error);
    }
    return ok ? JNI_TRUE : JNI_FALSE;
}

RIMES_JNI(jboolean, isHealthy)(JNIEnv*, jclass) {
    return BBRimeIsHealthy() ? JNI_TRUE : JNI_FALSE;
}

RIMES_JNI(jboolean, hasOctagram)(JNIEnv*, jclass) {
    return BBRimeHasOctagram() ? JNI_TRUE : JNI_FALSE;
}

RIMES_JNI(jlong, createSession)(JNIEnv*, jclass) {
    return static_cast<jlong>(BBRimeCreateSession());
}

RIMES_JNI(void, destroySession)(JNIEnv*, jclass, jlong session) {
    BBRimeDestroySession(static_cast<uint64_t>(session));
}

RIMES_JNI(jboolean, sessionExists)(JNIEnv*, jclass, jlong session) {
    return BBRimeSessionExists(static_cast<uint64_t>(session)) ? JNI_TRUE : JNI_FALSE;
}

RIMES_JNI(jboolean, processKey)(JNIEnv*, jclass, jlong session, jint keycode, jint mask) {
    return BBRimeProcessKey(static_cast<uint64_t>(session), keycode, mask) ? JNI_TRUE : JNI_FALSE;
}

RIMES_JNI(jboolean, commitComposition)(JNIEnv*, jclass, jlong session) {
    return BBRimeCommitComposition(static_cast<uint64_t>(session)) ? JNI_TRUE : JNI_FALSE;
}

RIMES_JNI(void, clearComposition)(JNIEnv*, jclass, jlong session) {
    BBRimeClearComposition(static_cast<uint64_t>(session));
}

RIMES_JNI(jboolean, selectCandidateOnCurrentPage)(JNIEnv*, jclass, jlong session, jint index) {
    if (index < 0) return JNI_FALSE;
    return BBRimeSelectCandidateOnCurrentPage(static_cast<uint64_t>(session),
                                              static_cast<uint64_t>(index))
        ? JNI_TRUE : JNI_FALSE;
}

RIMES_JNI(jboolean, getOption)(JNIEnv* env, jclass, jlong session, jstring option) {
    const std::string name = toStdString(env, option);
    return BBRimeGetOption(static_cast<uint64_t>(session), name.c_str()) ? JNI_TRUE : JNI_FALSE;
}

RIMES_JNI(void, setOption)(JNIEnv* env, jclass, jlong session, jstring option, jboolean value) {
    const std::string name = toStdString(env, option);
    BBRimeSetOption(static_cast<uint64_t>(session), name.c_str(), value == JNI_TRUE);
}

RIMES_JNI(jboolean, selectSchema)(JNIEnv* env, jclass, jlong session, jstring schemaId) {
    const std::string id = toStdString(env, schemaId);
    return BBRimeSelectSchema(static_cast<uint64_t>(session), id.c_str()) ? JNI_TRUE : JNI_FALSE;
}

RIMES_JNI(jboolean, deploy)(JNIEnv*, jclass) {
    return BBRimeDeploy() ? JNI_TRUE : JNI_FALSE;
}

// Returns NaN when the key is missing so Kotlin can map it to null.
RIMES_JNI(jdouble, configDouble)(JNIEnv* env, jclass, jstring configId, jstring key) {
    const std::string config = toStdString(env, configId);
    const std::string path = toStdString(env, key);
    double value = 0;
    if (!BBRimeConfigGetDouble(config.c_str(), path.c_str(), &value)) {
        return static_cast<jdouble>(__builtin_nan(""));
    }
    return value;
}

RIMES_JNI(jobjectArray, schemaList)(JNIEnv* env, jclass) {
    jclass itemClass = findClass(env, "RimeSchemaItem");
    if (!itemClass) return nullptr;
    jmethodID ctor = env->GetMethodID(itemClass, "<init>",
                                      "(Ljava/lang/String;Ljava/lang/String;)V");
    if (!ctor) return nullptr;

    BBRimeSchema buffer[64];
    memset(buffer, 0, sizeof(buffer));
    const int count = BBRimeGetSchemaList(buffer, 64);
    std::vector<std::pair<std::string, std::string>> copied;
    copied.reserve(count > 0 ? static_cast<size_t>(count) : 0);
    for (int i = 0; i < count; ++i) {
        copied.emplace_back(buffer[i].id ? buffer[i].id : "",
                            buffer[i].name ? buffer[i].name : "");
    }

    jobjectArray result = env->NewObjectArray(static_cast<jsize>(copied.size()), itemClass, nullptr);
    if (!result) return nullptr;
    for (size_t i = 0; i < copied.size(); ++i) {
        jstring id = toJavaString(env, copied[i].first.c_str());
        jstring name = toJavaString(env, copied[i].second.c_str());
        jobject item = env->NewObject(itemClass, ctor, id, name);
        env->SetObjectArrayElement(result, static_cast<jsize>(i), item);
        env->DeleteLocalRef(item);
        env->DeleteLocalRef(id);
        env->DeleteLocalRef(name);
    }
    return result;
}

RIMES_JNI(jobject, getContext)(JNIEnv* env, jclass, jlong session) {
    BBRimeContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    if (!BBRimeGetContext(static_cast<uint64_t>(session), &ctx)) return nullptr;

    // Copy everything before any JNI call that could re-enter the bridge.
    struct Candidate {
        std::string text;
        std::string comment;
        std::string label;
    };
    std::vector<Candidate> candidates;
    const int count = ctx.numCandidates < BB_MAX_CANDIDATES ? ctx.numCandidates : BB_MAX_CANDIDATES;
    candidates.reserve(count > 0 ? static_cast<size_t>(count) : 0);
    for (int i = 0; i < count; ++i) {
        candidates.push_back({ctx.candidates[i].text ? ctx.candidates[i].text : "",
                              ctx.candidates[i].comment ? ctx.candidates[i].comment : "",
                              ctx.candidates[i].label ? ctx.candidates[i].label : ""});
    }
    const std::string preedit = ctx.preedit ? ctx.preedit : "";
    const std::string input = ctx.input ? ctx.input : "";

    jclass candidateClass = findClass(env, "RimeCandidateModel");
    jclass contextClass = findClass(env, "RimeContextModel");
    if (!candidateClass || !contextClass) return nullptr;
    jmethodID candidateCtor = env->GetMethodID(
        candidateClass, "<init>",
        "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V");
    jmethodID contextCtor = env->GetMethodID(
        contextClass, "<init>",
        "(ZLjava/lang/String;Ljava/lang/String;IIIIIZI[Lcom/isaac/inputmethod/rimes/rime/RimeCandidateModel;)V");
    if (!candidateCtor || !contextCtor) return nullptr;

    jobjectArray array = env->NewObjectArray(static_cast<jsize>(candidates.size()), candidateClass, nullptr);
    if (!array) return nullptr;
    for (size_t i = 0; i < candidates.size(); ++i) {
        jstring text = toJavaString(env, candidates[i].text.c_str());
        jstring comment = toJavaString(env, candidates[i].comment.c_str());
        jstring label = toJavaString(env, candidates[i].label.c_str());
        jobject candidate = env->NewObject(candidateClass, candidateCtor, text, comment, label);
        env->SetObjectArrayElement(array, static_cast<jsize>(i), candidate);
        env->DeleteLocalRef(candidate);
        env->DeleteLocalRef(text);
        env->DeleteLocalRef(comment);
        env->DeleteLocalRef(label);
    }

    jstring jPreedit = toJavaString(env, preedit.c_str());
    jstring jInput = toJavaString(env, input.c_str());
    return env->NewObject(contextClass, contextCtor,
                          ctx.active ? JNI_TRUE : JNI_FALSE,
                          jPreedit, jInput,
                          ctx.cursorPos, ctx.selStart, ctx.selEnd,
                          ctx.pageSize, ctx.pageNo,
                          ctx.isLastPage ? JNI_TRUE : JNI_FALSE,
                          ctx.highlightedIndex,
                          array);
}

RIMES_JNI(jobject, getStatus)(JNIEnv* env, jclass, jlong session) {
    BBRimeStatus status;
    memset(&status, 0, sizeof(status));
    if (!BBRimeGetStatus(static_cast<uint64_t>(session), &status)) return nullptr;
    const std::string schemaId = status.schemaId ? status.schemaId : "";
    const std::string schemaName = status.schemaName ? status.schemaName : "";

    jclass statusClass = findClass(env, "RimeStatusModel");
    if (!statusClass) return nullptr;
    jmethodID ctor = env->GetMethodID(statusClass, "<init>",
                                      "(Ljava/lang/String;Ljava/lang/String;ZZZZZZZ)V");
    if (!ctor) return nullptr;
    jstring jId = toJavaString(env, schemaId.c_str());
    jstring jName = toJavaString(env, schemaName.c_str());
    return env->NewObject(statusClass, ctor, jId, jName,
                          status.asciiMode ? JNI_TRUE : JNI_FALSE,
                          status.fullShape ? JNI_TRUE : JNI_FALSE,
                          status.simplified ? JNI_TRUE : JNI_FALSE,
                          status.traditional ? JNI_TRUE : JNI_FALSE,
                          status.asciiPunct ? JNI_TRUE : JNI_FALSE,
                          status.composing ? JNI_TRUE : JNI_FALSE,
                          status.disabled ? JNI_TRUE : JNI_FALSE);
}

RIMES_JNI(jstring, takeCommit)(JNIEnv* env, jclass, jlong session) {
    return takeBridgeString(env, BBRimeCopyCommit(static_cast<uint64_t>(session)));
}

RIMES_JNI(jstring, currentSchema)(JNIEnv* env, jclass, jlong session) {
    return takeBridgeString(env, BBRimeCopySchema(static_cast<uint64_t>(session)));
}

RIMES_JNI(jstring, lastError)(JNIEnv* env, jclass) {
    jstring result = takeBridgeString(env, BBRimeCopyLastError());
    return result ? result : env->NewStringUTF("");
}

RIMES_JNI(jobjectArray, decodeCandidateTexts)(JNIEnv* env, jclass, jlong session,
                                              jstring input, jint maxCount) {
    if (maxCount <= 0) maxCount = 1;
    if (maxCount > 5) maxCount = 5;
    const std::string raw = toStdString(env, input);
    const size_t stride = 4096;
    std::vector<char> storage(stride * static_cast<size_t>(maxCount), 0);
    const int count = BBRimeDecodeCandidateTexts(static_cast<uint64_t>(session),
                                                 raw.c_str(),
                                                 storage.data(),
                                                 static_cast<uint64_t>(stride),
                                                 maxCount);
    if (count < 0) return nullptr;
    jclass stringClass = env->FindClass("java/lang/String");
    jobjectArray result = env->NewObjectArray(count, stringClass, nullptr);
    for (int i = 0; i < count; ++i) {
        jstring text = toJavaString(env, storage.data() + stride * static_cast<size_t>(i));
        env->SetObjectArrayElement(result, i, text);
        env->DeleteLocalRef(text);
    }
    return result;
}

RIMES_JNI(jboolean, hasUserDictionary)(JNIEnv* env, jclass, jstring dictName) {
    const std::string name = toStdString(env, dictName);
    return BBRimeHasUserDictionary(name.c_str()) ? JNI_TRUE : JNI_FALSE;
}

RIMES_JNI(jint, exportUserDictionary)(JNIEnv* env, jclass, jstring dictName, jstring textFile) {
    const std::string name = toStdString(env, dictName);
    const std::string path = toStdString(env, textFile);
    return BBRimeExportUserDictionary(name.c_str(), path.c_str());
}

RIMES_JNI(jint, importUserDictionary)(JNIEnv* env, jclass, jstring dictName, jstring textFile) {
    const std::string name = toStdString(env, dictName);
    const std::string path = toStdString(env, textFile);
    return BBRimeImportUserDictionary(name.c_str(), path.c_str());
}

RIMES_JNI(jboolean, restoreUserDictionarySnapshot)(JNIEnv* env, jclass, jstring snapshotFile) {
    const std::string path = toStdString(env, snapshotFile);
    return BBRimeRestoreUserDictionarySnapshot(path.c_str()) ? JNI_TRUE : JNI_FALSE;
}

#undef RIMES_JNI

}  // extern "C"
