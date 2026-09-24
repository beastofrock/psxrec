#!/usr/bin/env bash
echo"
.
├── disc/
│   ├── disc.cue
│   └── *.bin
├── SCPH1001.BIN
└── psxrecomp/
"

git clone --recurse-submodules https://github.com/RetroPortingToolKit/psxrecomp.git
cd psxrecomp
cmake -S recompiler -B recompiler/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build recompiler/build
cp ../SCPH1001.BIN bios/
bash tools/regen_bios.sh --config bios/SCPH1001.toml

sh tools/new_project_layout/setup_project.sh \
  --disc ../disc/disc.cue \
  --bios ../SCPH1001.BIN \
  --dir ..

cp ../fix-psxrecomp-sdl3.sh ../wipeoutxlRecomp/
cd ../wipeoutxlRecomp
./fix-psxrecomp-sdl3.sh

#echo "==> Running CMake configuration..."
#cmake -S . -B build-release \
#    -G Ninja \
#    -DCMAKE_BUILD_TYPE=Release \
#    -DSDL3_DIR=/usr/local/lib/cmake/SDL3 \
#    -DPSX_SDL3_FETCH=OFF

cmake --build build-release -j$(nproc)

cat > build-release/bios.cfg <<EOF
$(pwd)/build-release/bios/SCPH1001.BIN
EOF

cp ../SCPH1001.BIN build-release/bios/
./build-release/wipeoutxl_Recompiled

#--bios psxrecomp/bios/SCPH1001.BIN

#bios is enabled via cfg > working
