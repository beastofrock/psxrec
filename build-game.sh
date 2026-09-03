#!/usr/bin/env bash
set -euo pipefail

echo
echo "=============================================="
echo " PS1 Recomp + recomp-ui Universal Build"
echo "=============================================="
echo

read -rp "Game name / folder (e.g. mgsvr): " GAME

if [[ -z "$GAME" ]]; then
    echo "ERROR: Game name cannot be empty."
    exit 1
fi

ROOT="$HOME/ports"
GAME_ROOT="$ROOT/$GAME"

DISC_DIR="$GAME_ROOT/disc"
BIN="$DISC_DIR/disc.bin"
CUE="$DISC_DIR/disc.cue"
SYSTEM_CNF="$DISC_DIR/SYSTEM.CNF"

PSXRECOMP="$ROOT/psxrecomp"
PROJECT="$GAME_ROOT/${GAME}Recomp"

echo
echo "Game root : $GAME_ROOT"
echo "Disc      : $DISC_DIR"
echo "Project   : $PROJECT"
echo

# --------------------------------------------------
# Check game files
# --------------------------------------------------

if [[ ! -d "$GAME_ROOT" ]]; then
    echo "ERROR: Game folder does not exist:"
    echo "  $GAME_ROOT"
    exit 1
fi

if [[ ! -f "$BIN" ]]; then
    echo "ERROR: Missing:"
    echo "  $BIN"
    exit 1
fi

if [[ ! -f "$CUE" ]]; then
    echo "ERROR: Missing:"
    echo "  $CUE"
    exit 1
fi

if [[ ! -f "$SYSTEM_CNF" ]]; then
    echo "ERROR: Missing:"
    echo "  $SYSTEM_CNF"
    exit 1
fi

# --------------------------------------------------
# Find PS1 executable
# --------------------------------------------------

EXE_LIST=()

while IFS= read -r -d '' file; do
    EXE_LIST+=("$file")
done < <(
    find "$DISC_DIR" -maxdepth 1 -type f \
        \( -iname 'SLUS_*' \
        -o -iname 'SCUS_*' \
        -o -iname 'SLES_*' \
        -o -iname 'SCES_*' \
        -o -iname 'SLPS_*' \
        -o -iname 'SCPM_*' \) \
        -print0 | sort -z
)

if [[ ${#EXE_LIST[@]} -eq 0 ]]; then
    echo "ERROR: No PS1 game executable found in:"
    echo "  $DISC_DIR"
    echo
    echo "Expected something like:"
    echo "  SLUS_123.45"
    exit 1
fi

if [[ ${#EXE_LIST[@]} -eq 1 ]]; then
    EXE="${EXE_LIST[0]}"
else
    echo "Multiple PS1 executables found:"
    echo

    for i in "${!EXE_LIST[@]}"; do
        echo "  [$((i + 1))] $(basename "${EXE_LIST[$i]}")"
    done

    echo
    read -rp "Select executable [1-${#EXE_LIST[@]}]: " EXE_CHOICE

    if ! [[ "$EXE_CHOICE" =~ ^[0-9]+$ ]] ||
       (( EXE_CHOICE < 1 || EXE_CHOICE > ${#EXE_LIST[@]} )); then
        echo "ERROR: Invalid selection."
        exit 1
    fi

    EXE="${EXE_LIST[$((EXE_CHOICE - 1))]}"
fi

EXE_NAME="$(basename "$EXE")"

echo
echo "Game executable: $EXE_NAME"

echo
echo "SYSTEM.CNF:"
echo "----------------------------------------------"
cat "$SYSTEM_CNF"
echo "----------------------------------------------"
echo

# --------------------------------------------------
# Check dependencies
# --------------------------------------------------

command -v git >/dev/null 2>&1 || {
    echo "ERROR: git is not installed."
    exit 1
}

command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is not installed."
    exit 1
}

command -v cmake >/dev/null 2>&1 || {
    echo "ERROR: cmake is not installed."
    exit 1
}

# --------------------------------------------------
# Clone / update PSXRecomp
# --------------------------------------------------

mkdir -p "$ROOT"

if [[ ! -d "$PSXRECOMP/.git" ]]; then
    echo
    echo "==> Cloning PSXRecomp..."

    git clone --recurse-submodules \
        https://github.com/mstan/psxrecomp.git \
        "$PSXRECOMP"
else
    echo
    echo "==> Updating PSXRecomp..."

    git -C "$PSXRECOMP" pull --ff-only
    git -C "$PSXRECOMP" submodule update --init --recursive
fi

# --------------------------------------------------
# Create project if necessary
# --------------------------------------------------

if [[ ! -f "$PROJECT/game.toml" ]]; then

    echo
    echo "==> Creating project..."
    echo "    $PROJECT"

    rm -rf "$PROJECT"

    bash "$PSXRECOMP/tools/new_project_layout/setup_project.sh" \
        --disc "$CUE" \
        --dir "$GAME_ROOT" \
        --name "${GAME}Recomp" \
        --boot-exe "$EXE_NAME" \
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

# --------------------------------------------------
# Verify project
# --------------------------------------------------

if [[ ! -f "$PROJECT/game.toml" ]]; then
    echo
    echo "ERROR: Project was not created correctly:"
    echo "  $PROJECT"
    exit 1
fi

cd "$PROJECT"

echo
echo "==> Project:"
pwd

# --------------------------------------------------
# Make sure submodules exist
# --------------------------------------------------

echo
echo "==> Updating project submodules..."

git submodule update --init --recursive || true

# --------------------------------------------------
# Make sure recomp-ui exists
# --------------------------------------------------

if [[ ! -d "$PROJECT/recomp-ui" ]]; then
    echo
    echo "==> Adding recomp-ui..."

    git submodule add \
        https://github.com/mstan/recomp-ui.git \
        recomp-ui

    git submodule update --init --recursive
fi

if [[ ! -f "$PROJECT/recomp-ui/recomp_ui.cmake" ]]; then
    echo
    echo "ERROR: recomp-ui is missing or incomplete."
    exit 1
fi

# --------------------------------------------------
# Make sure project PSXRecomp exists
# --------------------------------------------------

if [[ ! -f "$PROJECT/psxrecomp/psxrecomp_cli.py" ]]; then
    echo
    echo "ERROR: PSXRecomp submodule is missing."
    exit 1
fi

# --------------------------------------------------
# Build emitters
# --------------------------------------------------

echo
echo "==> Building PSXRecomp emitters..."

bash "$PROJECT/psxrecomp/tools/ci/build_emitters.sh"

# --------------------------------------------------
# Generate fresh source
# --------------------------------------------------

echo
echo "==> Removing old generated code..."

rm -rf "$PROJECT/generated"

echo
echo "==> Generating recompiled source..."

python3 "$PROJECT/psxrecomp/psxrecomp_cli.py" generate \
    --config "$PROJECT/game.toml" \
    --project-root "$PROJECT" \
    --disc "$CUE"

# --------------------------------------------------
# CMake configure
# --------------------------------------------------

echo
echo "==> Configuring CMake..."

cmake -S "$PROJECT" \
    -B "$PROJECT/build-release" \
    -DCMAKE_BUILD_TYPE=Release \
    -DPSX_RECOMP_UI:BOOL=ON \
    -DRECOMP_UI_ENABLE_MODS:BOOL=ON

# --------------------------------------------------
# Build
# --------------------------------------------------

echo
echo "==> Building psx-runtime..."

cmake --build "$PROJECT/build-release" \
    --target psx-runtime \
    -j"$(nproc)"

# --------------------------------------------------
# Find executable
# --------------------------------------------------

echo
echo "=============================================="
echo " BUILD COMPLETE"
echo "=============================================="
echo

FOUND_EXE=""

if [[ -f "$PROJECT/build-release/psx-runtime" ]]; then
    FOUND_EXE="$PROJECT/build-release/psx-runtime"
else
    FOUND_EXE="$(
        find "$PROJECT/build-release" \
            -type f \
            -perm -111 \
            2>/dev/null |
        grep -E '/psx-runtime$' |
        head -n 1 || true
    )"
fi

if [[ -n "$FOUND_EXE" ]]; then
    echo "Executable:"
    echo "  $FOUND_EXE"
else
    echo "Build succeeded, but psx-runtime executable was not found automatically."
    echo
    echo "Check:"
    echo "  $PROJECT/build-release/"
fi

echo
echo "Project:"
echo "  $PROJECT"
echo
echo "Disc:"
echo "  $CUE"
echo
echo "Game:"
echo "  $EXE_NAME"
echo
echo "recomp-ui: ENABLED"
echo 
#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Universal PS1 PSXRecomp + recomp-ui builder
#
# Usage:
#   ./build-gui.sh
#
# Expected:
#   ~/ports/<game>/disc/disc.bin
#   ~/ports/<game>/disc/disc.cue
#   ~/ports/<game>/disc/SYSTEM.CNF
#   ~/ports/<game>/disc/SLUS_xxx.xx
# ============================================================

ROOT="$HOME/ports"

echo "============================================================"
echo " Universal PSXRecomp + recomp-ui builder"
echo "============================================================"
echo

# ============================================================
# 1. Ask for game name
# ============================================================

read -rp "Game name/folder (e.g. mgsvr): " GAME

if [ -z "$GAME" ]; then
    echo "ERROR: Game name cannot be empty."
    exit 1
fi

# Basic safety: only allow normal folder names.
if [[ ! "$GAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: Invalid game name."
    echo "Use only letters, numbers, '.', '_' and '-'."
    exit 1
fi

GAME_ROOT="$ROOT/$GAME"
DISC_DIR="$GAME_ROOT/disc"

BIN="$DISC_DIR/disc.bin"
CUE="$DISC_DIR/disc.cue"
SYSTEM_CNF="$DISC_DIR/SYSTEM.CNF"

PSXRECOMP="$ROOT/psxrecomp"
PROJECT="$GAME_ROOT/${GAME}Recomp"

echo
echo "============================================================"
echo " Game:       $GAME"
echo " Game root:  $GAME_ROOT"
echo " Disc:       $CUE"
echo " Project:    $PROJECT"
echo "============================================================"

# ============================================================
# 2. Check standard disc layout
# ============================================================

echo
echo "==> Checking disc..."

if [ ! -f "$BIN" ]; then
    echo "ERROR: Missing:"
    echo "  $BIN"
    exit 1
fi

if [ ! -f "$CUE" ]; then
    echo "ERROR: Missing:"
    echo "  $CUE"
    exit 1
fi

if [ ! -f "$SYSTEM_CNF" ]; then
    echo "ERROR: Missing:"
    echo "  $SYSTEM_CNF"
    exit 1
fi

# ============================================================
# 3. Find game executable
# ============================================================

echo
echo "==> Looking for game executable..."

mapfile -t EXES < <(
    find "$DISC_DIR" -maxdepth 1 -type f \
        \( \
            -iname 'SLUS_*' \
            -o -iname 'SCUS_*' \
            -o -iname 'SLES_*' \
            -o -iname 'SCES_*' \
            -o -iname 'SLPS_*' \
            -o -iname 'SCPM_*' \
        \) \
        -printf '%f\n' | sort
)

if [ "${#EXES[@]}" -eq 0 ]; then
    echo "ERROR: No PS1 game executable found in:"
    echo "  $DISC_DIR"
    echo
    echo "Expected something like:"
    echo "  SLUS_012.34"
    exit 1
fi

if [ "${#EXES[@]}" -gt 1 ]; then
    echo "Multiple game executables found:"
    printf '  %s\n' "${EXES[@]}"
    echo
    read -rp "Enter the executable filename to use: " EXE
else
    EXE="${EXES[0]}"
fi

EXE_PATH="$DISC_DIR/$EXE"

if [ ! -f "$EXE_PATH" ]; then
    echo "ERROR: Executable not found:"
    echo "  $EXE_PATH"
    exit 1
fi

echo "    Boot executable: $EXE"

# ============================================================
# 4. Read SYSTEM.CNF
# ============================================================

echo
echo "==> SYSTEM.CNF:"

cat "$SYSTEM_CNF"

# Extract BOOT line if available.
BOOT_LINE=$(grep -iE '^[[:space:]]*BOOT[[:space:]]*=' "$SYSTEM_CNF" \
    | head -n1 || true)

if [ -n "$BOOT_LINE" ]; then
    echo
    echo "    $BOOT_LINE"
fi

# ============================================================
# 5. Clone / update PSXRecomp
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
# 6. Create project if missing
# ============================================================

if [ ! -f "$PROJECT/game.toml" ]; then

    echo
    echo "==> Creating project..."

    mkdir -p "$GAME_ROOT/${GAME}-recomp"

    bash "$PSXRECOMP/tools/new_project_layout/setup_project.sh" \
        --disc "$CUE" \
        --dir "$GAME_ROOT/${GAME}-recomp" \
        --name "${GAME}Recomp" \
        --boot-exe "$EXE" \
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
# 7. Verify project
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
# 8. Initialize/update project submodules
# ============================================================

echo
echo "==> Updating project submodules..."

git submodule sync --recursive
git submodule update --init --recursive

# ============================================================
# 9. Verify recomp-ui
# ============================================================

if [ ! -d "$PROJECT/recomp-ui" ]; then
    echo
    echo "ERROR: recomp-ui missing."
    exit 1
fi

echo "    recomp-ui: OK"

# ============================================================
# 10. Verify boot EXE and seeds
# ============================================================

if [ ! -f "$PROJECT/disc/$EXE" ]; then
    echo
    echo "ERROR: Boot executable was not copied into project:"
    echo "  $PROJECT/disc/$EXE"
    exit 1
fi

if [ ! -f "$PROJECT/seeds/ghidra_funcs.txt" ]; then
    echo
    echo "ERROR: Seed file missing:"
    echo "  $PROJECT/seeds/ghidra_funcs.txt"
    exit 1
fi

echo "    boot EXE: OK"
echo "    seeds:    $(grep -c '^0x' "$PROJECT/seeds/ghidra_funcs.txt")"

# ============================================================
# 11. Build emitters
# ============================================================

echo
echo "==> Building PSXRecomp emitters..."

cd "$PROJECT"

bash "$PSXRECOMP/tools/ci/build_emitters.sh"

# ============================================================
# 12. Generate game
# ============================================================

echo
echo "==> Removing previous generated output..."

rm -rf generated

echo
echo "==> Generating $GAME..."

python3 psxrecomp/psxrecomp_cli.py generate \
    --config game.toml \
    --project-root . \
    --disc "$CUE"

# ============================================================
# 13. Configure CMake + recomp-ui
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
# 14. Show UI configuration
# ============================================================

echo
echo "==> UI configuration:"

cmake -LA -N build-release 2>/dev/null \
    | grep -E 'PSX_RECOMP_UI|RECOMP_UI_ENABLE_MODS' \
    || true

# ============================================================
# 15. Build runtime
# ============================================================

echo
echo "==> Building psx-runtime..."

cmake --build build-release \
    --target psx-runtime \
    -j"$(nproc)"

# ============================================================
# 16. Find executable
# ============================================================

echo
echo "============================================================"
echo " BUILD COMPLETE"
echo "============================================================"
echo

echo "Game:"
echo "  $GAME"

echo
echo "Boot executable:"
echo "  $EXE"

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
    \( \
        -name 'psx-runtime*' \
        -o -name '*Recompiled*' \
    \) \
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
