#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# MyGame
# PSXRecomp + recomp-ui — complete local build
# ============================================================

GAME="fifa98"
ROOT="$HOME/ports/$GAME"
PSXRECOMP="$ROOT/psxrecomp"
PROJECT="$ROOT/$GAME/gameRecomp"
DISC="$ROOT/disc/disc.cue"

echo "============================================================"
echo " $GAME"
echo " PSXRecomp + recomp-ui"
echo "============================================================"

# ============================================================
# 1. Check disc
# ============================================================

if [ ! -f "$DISC" ]; then
    echo "ERROR: Disc CUE not found:"
    echo "  $DISC"
    exit 1
fi

mkdir -p "$ROOT"

echo
echo "==> Disc:"
echo "    $DISC"

# ============================================================
# 2. Clone / update PSXRecomp
# ============================================================

echo
echo "==> Updating PSXRecomp..."

if [ ! -d "$PSXRECOMP/.git" ]; then

    git clone --recurse-submodules \
        https://github.com/mstan/psxrecomp.git \
        "$PSXRECOMP"

else

    cd "$PSXRECOMP"

    git fetch --all --tags
    git pull --ff-only

    git submodule sync --recursive
    git submodule update --init --recursive

fi

# ============================================================
# 3. Create project if missing
# ============================================================

if [ ! -f "$PROJECT/game.toml" ]; then

    echo
    echo "==> Creating $GAME project..."

    mkdir -p "$ROOT/$GAME-recomp"

    bash "$PSXRECOMP/tools/new_project_layout/setup_project.sh" \
        --disc "$DISC" \
        --dir "$ROOT/$GAME-recomp" \
        --name "$GAMERecomp" \
        --enable-recomp-ui \
        --no-wizard \
        --no-netplay \
        --no-ci \
        --no-fetch-boxart \
        --no-generate \
        --no-build \
        --no-github \
        --yes

fi

# ============================================================
# 4. Verify project
# ============================================================

if [ ! -f "$PROJECT/game.toml" ]; then
    echo
    echo "ERROR: Project creation failed."
    echo "Expected:"
    echo "  $PROJECT/game.toml"
    exit 1
fi

cd "$PROJECT"

echo
echo "==> Project:"
echo "    $PROJECT"

# ============================================================
# 5. Initialize/update project submodules
# ============================================================

echo
echo "==> Updating project submodules..."

git submodule sync --recursive
git submodule update --init --recursive

# ============================================================
# 6. Verify recomp-ui
# ============================================================

if [ ! -d "$PROJECT/recomp-ui" ]; then
    echo "ERROR: recomp-ui missing."
    exit 1
fi

echo "    recomp-ui: OK"

# ============================================================
# 7. Verify boot EXE / seeds
# ============================================================

if [ ! -f "$PROJECT/disc/SLUS_009.57" ]; then
    echo "ERROR: SLUS_009.57 was not extracted."
    exit 1
fi

if [ ! -f "$PROJECT/seeds/ghidra_funcs.txt" ]; then
    echo "ERROR: seed file missing."
    exit 1
fi

echo "    boot EXE:  OK"
echo "    seeds:     $(grep -c '^0x' "$PROJECT/seeds/ghidra_funcs.txt")"

# ============================================================
# 8. Build emitters
# ============================================================

echo
echo "==> Building PSXRecomp emitters..."

cd "$PROJECT"

bash "$PSXRECOMP/tools/ci/build_emitters.sh"

# ============================================================
# 9. Generate $GAME
# ============================================================

echo
echo "==> Removing previous generated output..."

rm -rf generated

echo
echo "==> Generating $DISC ..."

python3 psxrecomp/psxrecomp_cli.py generate \
    --config game.toml \
    --project-root . \
    --disc "$DISC"

# ============================================================
# 10. Configure CMake + recomp-ui
# ============================================================

echo
echo "==> Configuring CMake..."

cmake -S . \
    -B build-release \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DPSX_RECOMP_UI:BOOL=ON \
    -DRECOMP_UI_ENABLE_MODS:BOOL=ON

# ============================================================
# 11. Show UI configuration
# ============================================================

echo
echo "==> UI configuration:"

cmake -LA -N build-release 2>/dev/null \
    | grep -E 'PSX_RECOMP_UI|RECOMP_UI_ENABLE_MODS' \
    || true

# ============================================================
# 12. Build runtime
# ============================================================

echo
echo "==> Building psx-runtime..."

cmake --build build-release \
    --target psx-runtime \
    -j"$(nproc)"

# ============================================================
# 13. Locate executable
# ============================================================

echo
echo "============================================================"
echo " BUILD COMPLETE"
echo "============================================================"
echo

echo "PSXRecomp:"
git -C "$PSXRECOMP" rev-parse --short HEAD

echo
echo "recomp-ui:"
git -C "$PROJECT/recomp-ui" rev-parse --short HEAD

echo
echo "Seeds:"
grep -c '^0x' "$PROJECT/seeds/ghidra_funcs.txt"

echo
echo "Executables:"
find "$PROJECT/build-release" \
    -type f \
    -executable \
    \( -name 'psx-runtime*' -o -name '*Recompiled*' \) \
    -print 2>/dev/null || true

echo
echo "Project:"
echo "  $PROJECT"

echo
echo "Build:"
echo "  $PROJECT/build-release"

echo
echo "Generated:"
echo "  $PROJECT/generated"

echo
echo "============================================================"
