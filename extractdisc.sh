#!/bin/bash
echo"cat disc.cue"
echo"FILE "disc.bin" BINARY"
echo"  TRACK 01 MODE2/2352"
echo"    INDEX 01 00:00:00"
echo "actual file: "
cat disc.cue
#sudo apt update
#sudo apt install bchunk
bchunk disc01.bin disc.cue disc
7z e disc01.iso SYSTEM.CNF SYSTEM.CNF
cat SYSTEM.CNF
echo "###"
bootfile=$(7z l disc01.iso | grep SLUS | cut -d' ' -f19)
echo "$bootfile"
7z e disc01.iso $bootfile $bootfile
rm disc01.iso
