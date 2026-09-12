#!/bin/bash
# =============================================================================
# Fetch the pinned static librime toolchain for Android into
# platforms/android/third_party/prebuilt (gitignored).
#
# Source: https://github.com/fcitx5-android/prebuilt — reproducible NDK builds
# of librime (with the lua/octagram/predict plugins merged), glog, leveldb,
# marisa-trie, OpenCC, yaml-cpp, Lua and Boost. The commit below is the only
# supply-chain input; git content addressing verifies every byte that is
# checked out. Update the pin deliberately and record the librime version.
#
#   ./scripts/fetch-prebuilt.sh            # skip when the pin is present
#   ./scripts/fetch-prebuilt.sh --force    # re-fetch
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

PREBUILT_REPO="https://github.com/fcitx5-android/prebuilt.git"
# 2026-07-29 "Auto update": librime 1.16.1 (rime/librime@de4700e), OpenCC
# BYVoid/OpenCC@907bfcb, built with NDK 28.0.13004108 against API 23.
PREBUILT_COMMIT="3587ba3355711f0aca50136e787719f6562676b8"
LIBRARIES=(librime boost glog leveldb lua marisa opencc yaml-cpp)
ABIS=(arm64-v8a x86_64)
DEST="third_party/prebuilt"
FORCE="${1:-}"

die() {
    echo "fetch-prebuilt: $*" >&2
    exit 1
}

[[ -z "$FORCE" || "$FORCE" == "--force" ]] \
    || die "the only supported option is --force"

if [[ "$FORCE" != "--force" && -d "$DEST/.git" ]] \
    && [[ "$(git -C "$DEST" rev-parse HEAD 2>/dev/null)" == "$PREBUILT_COMMIT" ]] \
    && [[ -f "$DEST/librime/x86_64/lib/librime.a" ]]; then
    echo "==> prebuilt pin $PREBUILT_COMMIT already present"
    exit 0
fi

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
echo "==> cloning $PREBUILT_REPO @ $PREBUILT_COMMIT (sparse)"
git clone --filter=blob:none --no-checkout "$PREBUILT_REPO" "$DEST"
paths=()
for library in "${LIBRARIES[@]}"; do
    for abi in "${ABIS[@]}"; do
        paths+=("$library/$abi")
    done
done
git -C "$DEST" sparse-checkout init --cone
git -C "$DEST" sparse-checkout set "${paths[@]}"
git -C "$DEST" checkout --detach "$PREBUILT_COMMIT"

actual="$(git -C "$DEST" rev-parse HEAD)"
[[ "$actual" == "$PREBUILT_COMMIT" ]] || die "checked out $actual, expected $PREBUILT_COMMIT"
for abi in "${ABIS[@]}"; do
    [[ -f "$DEST/librime/$abi/lib/librime.a" ]] || die "librime.a missing for $abi"
    [[ -f "$DEST/librime/$abi/include/rime_api.h" ]] || die "rime_api.h missing for $abi"
done
echo "==> prebuilt ready:"
du -sh "$DEST"/*/ | sed 's/^/    /'
