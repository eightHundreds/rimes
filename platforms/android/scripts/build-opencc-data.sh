#!/bin/bash
# =============================================================================
# Build the stock OpenCC configuration and dictionaries on the host and place
# them in platforms/android/third_party/opencc-data (gitignored).
#
# The reviewed rime-data closure declares `opencc/s2t.json` and its
# dictionaries as an external runtime dependency (see CROSS-PLATFORM-PREVIEW.md).
# macOS receives them from Squirrel's SharedSupport; Windows/Linux from the
# system Rime frontend. Android bundles them, so they are generated here from
# the same OpenCC commit that the pinned prebuilt libopencc.a was built from.
# The .ocd2 format is architecture independent.
#
# Requires: git, cmake, ninja (or make), a host C++17 compiler, python3.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

OPENCC_REPO="https://github.com/BYVoid/OpenCC.git"
OPENCC_COMMIT="907bfcbbd3aae86ff04bc8eaca67c8af03108ddf"
WORK="third_party/opencc-build"
DEST="third_party/opencc-data"

die() {
    echo "build-opencc-data: $*" >&2
    exit 1
}

if [[ -f "$DEST/s2t.json" && -f "$DEST/STPhrases.ocd2" && "${1:-}" != "--force" ]]; then
    echo "==> OpenCC data already present in $DEST"
    exit 0
fi

rm -rf "$WORK" "$DEST"
mkdir -p "$WORK"
echo "==> cloning OpenCC @ $OPENCC_COMMIT"
git clone "$OPENCC_REPO" "$WORK/src"
git -C "$WORK/src" checkout --detach "$OPENCC_COMMIT"
git -C "$WORK/src" submodule update --init --depth 1 >/dev/null 2>&1 || true

generator=()
if command -v ninja >/dev/null 2>&1; then
    generator=(-G Ninja)
fi
cmake -S "$WORK/src" -B "$WORK/build" "${generator[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_DOCUMENTATION=OFF \
    -DENABLE_GTEST=OFF \
    -DBUILD_PYTHON=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_PREFIX="$WORK/install"
cmake --build "$WORK/build" --parallel "$(nproc 2>/dev/null || echo 4)"
cmake --install "$WORK/build" >/dev/null

mkdir -p "$DEST"
cp "$WORK/install/share/opencc/"*.json "$WORK/install/share/opencc/"*.ocd2 "$DEST/"
cp "$WORK/src/LICENSE" "$DEST/LICENSE.opencc"
[[ -f "$DEST/s2t.json" && -f "$DEST/STPhrases.ocd2" ]] || die "expected s2t.json/STPhrases.ocd2 in $DEST"
echo "==> OpenCC data ready:"
ls "$DEST" | sed 's/^/    /'
