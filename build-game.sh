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
BIN="$DISC_DIR/disc01.bin"
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
