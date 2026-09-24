#!/usr/bin/env bash
set -euo pipefail

# only needed on debian 12, as no sdl3 in repos

FILE="psxrecomp/runtime/runtime.cmake"

if [[ ! -f "$FILE" ]]; then
    echo "ERROR: $FILE not found."
    echo "Run this script from the wipeoutxlRecomp repository root."
    exit 1
fi

echo "==> Backing up $FILE"
cp -n "$FILE" "$FILE.bak"

echo "==> Checking current SDL3 check..."

if ! grep -q '_psx_header_compiles(_psx_sdl3_ok "SDL3/SDL.h" LIBRARIES SDL3::SDL3)' "$FILE"; then
    echo "ERROR: Expected SDL3 line was not found."
    echo
    echo "The file may already be patched, or this checkout differs"
    echo "from the version this script expects."
    echo
    grep -n -A5 -B5 '_psx_sdl3_ok' "$FILE" || true
    exit 1
fi

python3 - "$FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = '''        _psx_header_compiles(_psx_sdl3_ok "SDL3/SDL.h" LIBRARIES SDL3::SDL3)
'''

new = '''        # CMake 3.25's check_include_file() creates a scratch project.
        # Imported targets such as SDL3::SDL3 are not available in that
        # scratch project, even though they exist in the parent project.
        #
        # Resolve SDL3 to its real include directory and shared-library path
        # before invoking check_include_file().
        get_target_property(_psx_sdl3_includes
            SDL3::Headers INTERFACE_INCLUDE_DIRECTORIES)

        get_target_property(_psx_sdl3_lib
            SDL3::SDL3 IMPORTED_LOCATION_RELEASE)

        if(NOT _psx_sdl3_lib)
            get_target_property(_psx_sdl3_lib
                SDL3::SDL3 IMPORTED_LOCATION)
        endif()

        if(NOT _psx_sdl3_lib)
            get_target_property(_psx_sdl3_lib
                SDL3::SDL3-shared IMPORTED_LOCATION_RELEASE)
        endif()

        if(NOT _psx_sdl3_lib)
            get_target_property(_psx_sdl3_lib
                SDL3::SDL3-shared IMPORTED_LOCATION)
        endif()

        if(NOT _psx_sdl3_includes)
            message(FATAL_ERROR
                "psxrecomp: could not determine SDL3 include directory")
        endif()

        if(NOT _psx_sdl3_lib)
            message(FATAL_ERROR
                "psxrecomp: could not determine SDL3 library path")
        endif()

        _psx_header_compiles(
            _psx_sdl3_ok
            "SDL3/SDL.h"
            INCLUDES ${_psx_sdl3_includes}
            LIBRARIES ${_psx_sdl3_lib}
        )

        unset(_psx_sdl3_includes)
        unset(_psx_sdl3_lib)
'''

if old not in text:
    print("ERROR: Expected line was not found.", file=sys.stderr)
    sys.exit(1)

path.write_text(text.replace(old, new, 1))
PY

echo "==> Patch applied."
echo
echo "Changed SDL3 validation from:"
echo '    LIBRARIES SDL3::SDL3'
echo
echo "to a concrete include path + library path so the CMake"
echo "try_compile() scratch project does not need the imported target."
echo
echo "==> Removing old CMake configuration..."
rm -rf build-release

echo
echo "==> Running CMake configuration..."
cmake -S . -B build-release \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DSDL3_DIR=/usr/local/lib/cmake/SDL3 \
    -DPSX_SDL3_FETCH=OFF

echo
echo "============================================================"
echo "SUCCESS: CMake configuration completed."
echo "============================================================"
echo
echo "Build with:"
echo
echo "    cmake --build build-release -j$(nproc)"
echo
